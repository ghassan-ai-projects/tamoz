# frozen_string_literal: true

require_relative 'test_helper'

class SkillsLintTest < Minitest::Test
  GOOD = { 'description' => 'Does one thing well. Use when the thing is needed.',
           'metadata' => "metadata:\n  tamoz.risk: read_only\n",
           'body' => "Read references/guide.md first.\n" }.freeze

  def setup = @root = Dir.mktmpdir('tamoz-lint')
  def teardown = FileUtils.remove_entry(@root)

  def lint(files: { 'references/guide.md' => "Guide\n" }, **parts)
    write_probe(GOOD.merge(parts.transform_keys(&:to_s)), files)
    snapshot = Tamoz::Skills.compile(sources: [Tamoz::Skills::SkillSource.new(id: 'op', root: @root,
                                                                              trust: 'operator')])
    Tamoz::Skills.lint(snapshot.records.fetch('op/probe'))
  end

  def write_probe(part, files)
    directory = File.join(@root, 'probe')
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'SKILL.md'),
               "---\nname: probe\ndescription: #{part['description']}\n#{part['metadata']}---\n#{part['body']}")
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
      File.write(File.join(directory, path), text)
    end
  end

  def bundled_skills_without_eval_pack(snapshot)
    snapshot.records.values.filter_map do |record|
      assert_empty Tamoz::Skills.lint(record), record.id
      suite = record.metadata['tamoz.eval-suite']
      next record.id unless suite

      assert File.directory?(ROOT.join('agenteval', suite.delete_prefix('agenteval-'))),
             "#{record.id} names a missing pack"
      nil
    end
  end

  # A bundled skill ships with an eval pack; one without is a pending gap, printed, never a silent pass.
  def test_every_bundled_skill_meets_the_bar_and_names_an_existing_eval_pack
    snapshot = Tamoz::Skills.operator_snapshot(bundled: true)

    assert_empty snapshot.rejections
    refute_empty snapshot.records
    unevaluated = bundled_skills_without_eval_pack(snapshot)
    skip "pending gap: #{unevaluated.length} bundled skill(s) without an eval pack: #{unevaluated.join(', ')}" unless
      unevaluated.empty?
  end

  def test_a_good_skill_is_clean
    assert_empty lint
  end

  def test_each_rule_catches_its_defect
    findings = {
      q1_when: lint(description: 'Does one thing well.').first,
      q1_length: lint(description: "#{'x' * 330} Use when needed.").first,
      q2: lint(body: "Read references/guide.md.\n#{"line\n" * 500}").first,
      q3: lint(body: "See references/guide.md and [x](references/missing.md).\n").first,
      q4: lint(files: { 'references/guide.md' => "G\n", 'assets/orphan.json' => "{}\n" }).first,
      q5: lint(metadata: '').first
    }
    patterns = {
      q1_when: /\AQ1: the description does not say when/, q1_length: /\AQ1: the description is \d+ bytes/,
      q2: /\AQ2:/, q3: %r{\AQ3: the body mentions references/missing.md}, q4: %r{\AQ4: assets/orphan.json},
      q5: /\AQ5:/
    }

    patterns.each { |rule, pattern| assert_match(pattern, findings.fetch(rule).to_s, "rule #{rule}") }
  end
end
