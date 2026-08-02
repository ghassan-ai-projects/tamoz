# frozen_string_literal: true

require_relative "test_helper"

# P9-A: the inert skill compiler, its digests, its resource index, and the
# stage-1 catalog. Adversarial containment lives in agent_skills_adversarial_test.rb.
class AgentSkillsTest < Minitest::Test
  Skills = Tamoz::Agent::Skills

  def setup
    @dir = Dir.mktmpdir("tamoz-skills")
    @operator = File.join(@dir, "operator")
    FileUtils.mkdir_p(@operator)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # ---------------------------------------------------------------- fixtures --

  def write_skill(root, name, body: "Follow the bounded procedure.\n", frontmatter: nil, resources: {})
    directory = File.join(root, name)
    FileUtils.mkdir_p(directory)
    front = frontmatter || <<~YAML
      name: #{name}
      description: A bounded procedure for #{name}. Use it when the configured check fails.
      license: Apache-2.0
      compatibility: Requires Ruby.
      allowed-tools: [read_file, apply_patch, run_check]
      metadata:
        version: "1.0.0"
        tamoz.risk: guarded
    YAML
    File.write(File.join(directory, "SKILL.md"), "---\n#{front}---\n\n#{body}", encoding: Encoding::UTF_8)
    resources.each do |relative, content|
      target = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content, encoding: Encoding::UTF_8)
    end
    directory
  end

  def source(id: "operator", root: nil, trust: "operator", precedence: 0)
    Skills::SkillSource.new(id:, root: root || @operator, trust:, precedence:)
  end

  def compile(sources: [source], bindings: {})
    Skills::Compiler.new(sources:, bindings:).compile
  end

  # ------------------------------------------------------------------- basics --

  def test_compiles_a_portable_skill_into_an_immutable_content_addressed_record
    write_skill(@operator, "fix-answer", resources: {"references/how.md" => "Read broken.rb.\n"})
    snapshot = compile

    assert_empty snapshot.rejections
    assert_equal ["operator/fix-answer"], snapshot.records.keys
    record = snapshot.records.fetch("operator/fix-answer")

    assert_equal "fix-answer", record.name
    assert_equal "operator", record.source_id
    assert_equal "operator", record.source_trust
    assert_equal "1.0.0", record.version
    assert_equal "Apache-2.0", record.license
    assert_equal %w[apply_patch read_file run_check], record.requested_capabilities
    assert_match(/\Asha256:[0-9a-f]{64}\z/, record.tree_digest)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, record.manifest_digest)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, record.description_digest)
    assert record.frozen?
    assert record.resource_index.frozen?
    assert_equal ["SKILL.md", "references/how.md"], record.resource_index.keys
    assert_raises(FrozenError) { record.resource_index["evil"] = 1 }
  end

  def test_compilation_is_deterministic_and_independent_of_absolute_location
    write_skill(@operator, "fix-answer", resources: {"assets/data.txt" => "x\n"})
    first = compile.records.fetch("operator/fix-answer")

    other = File.join(@dir, "elsewhere")
    FileUtils.mkdir_p(other)
    write_skill(other, "fix-answer", resources: {"assets/data.txt" => "x\n"})
    second = compile(sources: [source(root: other)]).records.fetch("operator/fix-answer")

    assert_equal first.tree_digest, second.tree_digest, "tree identity must not depend on location"
    assert_equal compile.catalog_digest, compile.catalog_digest
  end

  def test_tree_digest_changes_on_body_description_content_and_executable_bit
    write_skill(@operator, "fix-answer", resources: {"references/how.md" => "one\n"})
    baseline = compile.records.fetch("operator/fix-answer").tree_digest

    write_skill(@operator, "fix-answer", body: "Different body.\n", resources: {"references/how.md" => "one\n"})
    body_changed = compile.records.fetch("operator/fix-answer").tree_digest

    refute_equal baseline, body_changed, "a body edit must change identity"

    File.write(File.join(@operator, "fix-answer", "references", "how.md"), "two\n")
    content_changed = compile.records.fetch("operator/fix-answer").tree_digest

    refute_equal body_changed, content_changed, "a resource edit must change identity"

    File.chmod(0o755, File.join(@operator, "fix-answer", "references", "how.md"))
    mode_changed = compile.records.fetch("operator/fix-answer").tree_digest

    refute_equal content_changed, mode_changed, "the executable bit is part of identity"
  end

  # A claimed version cannot prevent a same-version content swap (SKILLS_DESIGN §3).
  def test_same_version_content_swap_changes_identity_and_epoch
    write_skill(@operator, "fix-answer")
    before = compile

    write_skill(@operator, "fix-answer", body: "Malicious replacement.\n")
    after = compile

    assert_equal "1.0.0", after.records.fetch("operator/fix-answer").version
    refute_equal before.records.fetch("operator/fix-answer").tree_digest,
                 after.records.fetch("operator/fix-answer").tree_digest
    refute_equal before.epoch, after.epoch
  end

  def test_empty_snapshot_is_the_ordinary_output_of_compiling_zero_sources
    assert_equal Skills::Compiler.new(sources: []).compile.catalog_digest,
                 Skills::Snapshot.empty.catalog_digest
    assert_predicate Skills::Snapshot.empty, :empty?
    assert_match(/\Askills:1:sha256:[0-9a-f]{64}\z/, Skills::Snapshot.empty.epoch)
  end

  # ------------------------------------------------------------ catalog epoch --

  def test_catalog_digest_excludes_source_roots_but_includes_ids_trust_and_rejections
    write_skill(@operator, "fix-answer")
    baseline = compile

    moved = File.join(@dir, "moved")
    FileUtils.mkdir_p(moved)
    write_skill(moved, "fix-answer")

    assert_equal baseline.catalog_digest, compile(sources: [source(root: moved)]).catalog_digest,
                 "relocating a source must not change catalog identity"
    refute_equal baseline.catalog_digest,
                 compile(sources: [source(trust: "workspace")]).catalog_digest,
                 "source trust is part of catalog identity"

    FileUtils.mkdir_p(File.join(@operator, "not-a-skill"))
    with_rejection = compile

    refute_empty with_rejection.rejections
    refute_equal baseline.catalog_digest, with_rejection.catalog_digest,
                 "a rejection must be a visible epoch change"
  end

  def test_rejection_detail_is_excluded_from_the_catalog_digest
    write_skill(@operator, "fix-answer")
    FileUtils.mkdir_p(File.join(@operator, "broken-skill"))
    snapshot = compile
    rejection = snapshot.rejections.first
    mutated = snapshot.rejections.map { |entry| entry.with(detail: "completely different text") }

    assert_equal snapshot.catalog_digest,
                 Skills::Snapshot.catalog_digest(
                   records: snapshot.records, collisions: snapshot.collisions,
                   rejections: mutated, bindings: snapshot.bindings, sources: snapshot.sources
                 )
    refute_nil rejection
  end

  # ---------------------------------------------------------------- collisions --

  def test_same_name_across_sources_never_shadows_silently
    workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(workspace)
    write_skill(@operator, "helper")
    write_skill(workspace, "helper", body: "Workspace impostor.\n")
    snapshot = compile(
      sources: [source, source(id: "workspace", root: workspace, trust: "workspace")]
    )

    assert_equal %w[operator/helper workspace/helper], snapshot.records.keys.sort
    assert_equal 1, snapshot.collisions.length
    collision = snapshot.collisions.first

    assert_equal "helper", collision.name
    assert_nil collision.bound_to
    assert_equal "unbound", collision.reason

    catalog = Skills::Catalog.new(snapshot)
    error = assert_raises(Tamoz::Agent::ToolError) { catalog.resolve("helper") }

    assert_match(/\Askill_name_ambiguous:/, error.message)
    assert_match(/operator\/helper/, error.message)
    assert_match(/workspace\/helper/, error.message)
    assert_equal "operator/helper", catalog.resolve("operator/helper").id
    assert_equal "workspace/helper", catalog.resolve("workspace/helper").id
    assert_includes catalog.render, "! helper is ambiguous"
  end

  def test_an_explicit_operator_binding_chooses_without_deleting_the_loser
    workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(workspace)
    write_skill(@operator, "helper")
    write_skill(workspace, "helper", body: "Workspace impostor.\n")
    snapshot = compile(
      sources: [source, source(id: "workspace", root: workspace, trust: "workspace")],
      bindings: {"helper" => "operator"}
    )
    catalog = Skills::Catalog.new(snapshot)

    assert_equal "operator/helper", catalog.resolve("helper").id
    assert_equal "operator/helper", snapshot.collisions.first.bound_to
    assert_equal "operator_binding", snapshot.collisions.first.reason
    assert_equal "workspace/helper", catalog.resolve("workspace/helper").id
  end

  def test_a_binding_naming_a_source_without_that_name_is_a_visible_rejection
    workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(workspace)
    write_skill(@operator, "helper")
    write_skill(workspace, "helper")
    snapshot = compile(
      sources: [source, source(id: "workspace", root: workspace, trust: "workspace")],
      bindings: {"helper" => "nowhere"}
    )

    assert_equal ["skill_binding_unsatisfied"], snapshot.rejections.map(&:code)
    assert_nil snapshot.collisions.first.bound_to
    assert_raises(Tamoz::Agent::ToolError) { Skills::Catalog.new(snapshot).resolve("helper") }
  end

  def test_a_binding_with_no_collision_is_reported_rather_than_ignored
    write_skill(@operator, "helper")
    snapshot = compile(bindings: {"helper" => "operator"})

    assert_equal ["skill_binding_unsatisfied"], snapshot.rejections.map(&:code)
    assert_equal "operator/helper", Skills::Catalog.new(snapshot).resolve("helper").id
  end

  # ------------------------------------------------------------------ catalog --

  def test_catalog_render_is_deterministic_id_ordered_and_explicitly_truncated
    12.times { |index| write_skill(@operator, format("skill-%02d", index)) }
    catalog = Skills::Catalog.new(compile)
    rendered = catalog.render(budget_bytes: 400)

    assert_equal rendered, Skills::Catalog.new(compile).render(budget_bytes: 400)
    assert_match(/more entries not shown \(catalog budget 400 bytes exceeded\)/, rendered)
    lines = rendered.lines.map(&:chomp).reject { |line| line.start_with?("- ...") }

    assert_equal lines.sort, lines, "catalog lines must be id ordered"
    assert_operator rendered.bytesize, :<, 700
  end

  def test_catalog_truncates_long_descriptions_on_a_character_boundary
    long = "Ünicode description that keeps going. #{"é" * 400}"
    write_skill(
      @operator, "long-one",
      frontmatter: "name: long-one\ndescription: #{long}\n"
    )
    rendered = Skills::Catalog.new(compile).render

    assert_predicate rendered, :valid_encoding?
    assert_equal Encoding::UTF_8, rendered.encoding
    assert_includes rendered, "…(truncated)"
  end

  def test_catalog_summarises_rejections_rather_than_hiding_them
    write_skill(@operator, "fix-answer")
    FileUtils.mkdir_p(File.join(@operator, "no-manifest"))
    rendered = Skills::Catalog.new(compile).render

    assert_match(/! 1 skill\(s\) rejected: skill_manifest_missing x1/, rendered)
  end

  # ---------------------------------------------------------------- resources --

  def test_read_resource_returns_exact_indexed_bytes_and_only_from_readable_areas
    write_skill(
      @operator, "fix-answer",
      resources: {
        "references/how.md" => "Read broken.rb first.\n",
        "assets/data.txt" => "payload\n",
        "scripts/run.rb" => "puts :never_executed\n"
      }
    )
    record = compile.records.fetch("operator/fix-answer")

    assert_equal "Read broken.rb first.\n", Skills.read_resource(record, "references/how.md")
    assert_equal "payload\n", Skills.read_resource(record, "assets/data.txt")

    error = assert_raises(Tamoz::Agent::ToolError) { Skills.read_resource(record, "scripts/run.rb") }

    assert_match(/\Askill_resource_not_readable:/, error.message)

    manifest = assert_raises(Tamoz::Agent::ToolError) { Skills.read_resource(record, "SKILL.md") }

    assert_match(/\Askill_resource_not_readable:/, manifest.message)
  end

  def test_scripts_are_indexed_for_identity_even_though_they_are_unreadable
    write_skill(@operator, "fix-answer", resources: {"scripts/run.rb" => "puts 1\n"})
    before = compile.records.fetch("operator/fix-answer").tree_digest
    File.write(File.join(@operator, "fix-answer", "scripts", "run.rb"), "puts 2\n")

    refute_equal before, compile.records.fetch("operator/fix-answer").tree_digest
  end

  # ------------------------------------------------------------ argument guards --

  def test_source_and_compiler_arguments_are_validated_as_configuration_not_tool_results
    assert_raises(Skills::Error) { Skills::SkillSource.new(id: "Bad Id", root: @operator, trust: "operator") }
    assert_raises(Skills::Error) { Skills::SkillSource.new(id: "ok", root: @operator, trust: "root") }
    assert_raises(Skills::Error) { Skills::SkillSource.new(id: "ok", root: @operator, trust: "operator", precedence: -1) }
    assert_raises(Skills::Error) { Skills::Compiler.new(sources: [Object.new]) }
    assert_raises(Skills::Error) { Skills::Compiler.new(sources: [source, source]) }
    assert_raises(Skills::Error) { Skills::Compiler.new(sources: [], bindings: {1 => 2}) }
    assert_raises(Skills::Error) { Skills::Catalog.new(Object.new) }
  end

  def test_an_unavailable_source_is_a_rejection_not_an_exception
    snapshot = compile(sources: [source(root: File.join(@dir, "absent"))])

    assert_equal ["skill_source_unavailable"], snapshot.rejections.map(&:code)
    assert_empty snapshot.records
  end
end
