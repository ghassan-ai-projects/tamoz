# frozen_string_literal: true

require_relative "test_helper"

class SkillsSpecConformanceTest < Minitest::Test
  Skills = Tamoz::Skills

  def setup
    @root = Dir.mktmpdir("tamoz-skills-spec")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(name, frontmatter, files = {})
    directory = File.join(@root, name)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "SKILL.md"), "---\n#{frontmatter}---\n\nFollow the steps.\n")
    files.each do |relative, content|
      FileUtils.mkdir_p(File.dirname(File.join(directory, relative)))
      File.write(File.join(directory, relative), content)
    end
    directory
  end

  def minimal(name, extra = "")
    "name: #{name}\ndescription: A spec probe. Use when testing conformance.\n#{extra}"
  end

  def compile = Skills.compile(sources: [Skills::SkillSource.new(id: "op", root: @root, trust: "operator")])

  def record(name) = compile.records.fetch("op/#{name}")

  def rejection(name) = compile.rejections.find { |entry| entry.entry == name }

  def test_space_separated_allowed_tools_with_scoped_and_capitalised_tools
    write("spec-tools", minimal("spec-tools", "allowed-tools: Bash(git add:*) Bash(jq:*) Read\n"))

    assert_equal ["Bash(git add:*)", "Bash(jq:*)", "Read"], record("spec-tools").requested_capabilities
  end

  def test_comma_separated_and_list_allowed_tools
    write("comma-tools", minimal("comma-tools", "allowed-tools: Read, Grep, Glob\n"))
    write("list-tools", minimal("list-tools", "allowed-tools: [read_file, run_check]\n"))

    assert_equal %w[Glob Grep Read], record("comma-tools").requested_capabilities
    assert_equal %w[read_file run_check], record("list-tools").requested_capabilities
  end

  def test_files_and_directories_beside_skill_md_are_accepted
    write("pdf-forms", minimal("pdf-forms", "license: Proprietary. LICENSE.txt has complete terms\n"),
          "LICENSE.txt" => "terms\n", "forms.md" => "Form fields.\n", "templates/letter.md" => "Dear\n")

    assert_equal %w[LICENSE.txt SKILL.md forms.md templates/letter.md], record("pdf-forms").resource_index.keys.sort
  end

  def test_description_limit_counts_characters_not_bytes
    write("unicode-desc", "name: unicode-desc\ndescription: #{'é' * 1024}\n")
    write("unicode-long", "name: unicode-long\ndescription: #{'é' * 1025}\n")

    assert_equal 1024, record("unicode-desc").description.length
    assert_equal "skill_field_invalid", rejection("unicode-long").code
  end

  def test_dotfiles_are_ignored_and_do_not_change_identity
    clean = write("clean-skill", minimal("clean-skill"))
    digest = record("clean-skill").tree_digest
    File.write(File.join(clean, ".DS_Store"), "finder")
    FileUtils.mkdir_p(File.join(clean, ".git"))
    File.symlink("/etc/passwd", File.join(clean, ".git", "escape"))
    File.write(File.join(@root, ".DS_Store"), "finder")

    snapshot = compile

    assert_empty snapshot.rejections
    assert_equal digest, snapshot.records.fetch("op/clean-skill").tree_digest
    assert_equal ["SKILL.md"], snapshot.records.fetch("op/clean-skill").resource_index.keys
  end

  def test_spec_invalid_names_are_refused
    { "pdf--tools" => "skill_name_invalid", "pdf-" => "skill_name_invalid", "-pdf" => "skill_name_invalid",
      "a#{'b' * 64}" => "skill_name_invalid" }.each do |name, code|
      write(name, minimal(name))

      assert_equal code, rejection(name)&.code, name
    end
    write("named-right", minimal("named-wrong"))

    assert_equal "skill_name_mismatch", rejection("named-right").code
  end

  def test_spec_invalid_fields_are_refused
    write("empty-desc", "name: empty-desc\ndescription: \"\"\n")
    write("empty-compat", minimal("empty-compat", "compatibility: \"\"\n"))
    write("long-compat", minimal("long-compat", "compatibility: #{'x' * 501}\n"))
    write("ok-compat", minimal("ok-compat", "compatibility: #{'é' * 500}\n"))

    %w[empty-desc empty-compat long-compat].each { |name| assert_equal "skill_field_invalid", rejection(name)&.code, name }
    assert_equal 500, record("ok-compat").compatibility.length
  end

  def test_every_non_script_file_is_readable_and_scripts_are_not
    write("readable", minimal("readable"), "forms.md" => "Form fields.\n", "templates/a.md" => "A\n",
                                           "references/r.md" => "R\n", "scripts/run.sh" => "echo\n")
    readable = record("readable")

    assert_equal "Form fields.\n", Skills.read_resource(readable, "forms.md")
    assert_equal "A\n", Skills.read_resource(readable, "templates/a.md")
    error = assert_raises(Tamoz::Core::ToolArgumentError) { Skills.read_resource(readable, "scripts/run.sh") }
    assert_match(/skill_resource_not_readable/, error.message)
  end

  # ---- O2: a rejection names the skill; the path is in the detail -----------

  def test_a_rejection_names_the_skill_and_the_offending_path
    bad = write("bad-skill", minimal("bad-skill"), "references/ok.md" => "ok\n")
    File.symlink("/etc/passwd", File.join(bad, "references", "leak.md"))

    found = rejection("bad-skill")

    assert_equal "skill_entry_type_invalid", found.code
    assert_includes found.detail, "references/leak.md"
  end
end
