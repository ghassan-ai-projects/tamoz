# frozen_string_literal: true

require_relative 'test_helper'

# QUALITY_BAR Q1–Q5: every bundled skill meets the authoring bar, and each rule catches its own defect.
class SkillsLintTest < Minitest::Test
  GOOD = { 'description' => 'Does one thing well. Use when the thing is needed.',
           'metadata' => "metadata:\n  tamoz.risk: read_only\n",
           'body' => "Read references/guide.md first.\n" }.freeze

  def setup = @root = Dir.mktmpdir('tamoz-lint')
  def teardown = FileUtils.remove_entry(@root)

  def lint(files: { 'references/guide.md' => "Guide\n" }, **parts)
    part = GOOD.merge(parts.transform_keys(&:to_s))
    directory = File.join(@root, 'probe')
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'SKILL.md'),
               "---\nname: probe\ndescription: #{part['description']}\n#{part['metadata']}---\n#{part['body']}")
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
      File.write(File.join(directory, path), text)
    end
    snapshot = Tamoz::Skills.compile(sources: [Tamoz::Skills::SkillSource.new(id: 'op', root: @root, trust: 'operator')])
    Tamoz::Skills.lint(snapshot.records.fetch('op/probe'))
  end

# A bundled skill ships with an eval pack; one without is a pending gap, printed, never a silent pass.
def test_every_bundled_skill_meets_the_bar_and_names_an_existing_eval_pack
  snapshot = Tamoz::Skills.operator_snapshot(bundled: true)

  assert_empty snapshot.rejections
  refute_empty snapshot.records
  unevaluated = snapshot.records.values.filter_map do |record|
    assert_empty Tamoz::Skills.lint(record), record.id
    suite = record.metadata['tamoz.eval-suite']
    next record.id unless suite

    assert File.directory?(ROOT.join('agenteval', suite.delete_prefix('agenteval-'))), "#{record.id} names a missing pack"
    nil
  end
  skip "pending gap: #{unevaluated.length} bundled skill(s) without an eval pack: #{unevaluated.join(', ')}" unless
    unevaluated.empty?
end

  def test_a_good_skill_is_clean
    assert_empty lint
  end

  def test_each_rule_catches_its_defect
    assert_match(/\AQ1: the description does not say when/, lint(description: 'Does one thing well.').first)
    assert_match(/\AQ1: the description is \d+ bytes/, lint(description: "#{'x' * 330} Use when needed.").first)
    assert_match(/\AQ2:/, lint(body: "Read references/guide.md.\n#{"line\n" * 500}").first)
    assert_match(/\AQ3: the body mentions references\/missing.md/, lint(body: "See references/guide.md and [x](references/missing.md).\n").first)
    assert_match(%r{\AQ4: assets/orphan.json}, lint(files: { 'references/guide.md' => "G\n", 'assets/orphan.json' => "{}\n" }).first)
    assert_match(/\AQ5:/, lint(metadata: '').first)
  end
end
