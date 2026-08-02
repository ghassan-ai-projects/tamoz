# frozen_string_literal: true

require_relative "test_helper"

# P9-B: progressive disclosure through the ordinary tool boundary, the prompt
# surface epoch, and the durable exact-digest resume rule.
class AgentSkillsToolboxTest < Minitest::Test
  Skills = Tamoz::Agent::Skills
  Toolbox = Tamoz::Agent::Toolbox

  # Measured at 6dee1b6, before skills.rb existed. These pin the compatibility
  # half of plan review finding C-1: a toolbox with no skills must be
  # byte-identical to the pre-P9 surface, so every P8 profile keeps validating.
  PRE_P9_READ_ONLY_DIGEST =
    "sha256:0a3043f33e643f9d8f48f8c54bdd06cffeafec62538938e8bfb227f2ef0a86ee"
  PRE_P9_READ_WRITE_DIGEST =
    "sha256:a496742d64a97472be306d280f90397524989587f77ea82bc9e627bffa97b0ae"

  def setup
    @dir = Dir.mktmpdir("tamoz-skills-toolbox")
    @workspace = File.join(@dir, "workspace")
    @operator = File.join(@dir, "operator")
    FileUtils.mkdir_p(@workspace)
    FileUtils.mkdir_p(@operator)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_skill(name, body: "Read broken.rb, then patch it.\n", frontmatter: nil, resources: {}, root: nil)
    directory = File.join(root || @operator, name)
    FileUtils.mkdir_p(directory)
    front = frontmatter || <<~YAML
      name: #{name}
      description: A bounded procedure for #{name}.
      allowed-tools: [read_file, apply_patch, run_check]
      metadata:
        version: "1.0.0"
    YAML
    File.write(File.join(directory, "SKILL.md"), "---\n#{front}---\n#{body}", encoding: Encoding::UTF_8)
    resources.each do |relative, content|
      target = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content, encoding: Encoding::UTF_8)
    end
    directory
  end

  def snapshot(root: nil, id: "operator", trust: "operator")
    Skills::Compiler.new(
      sources: [Skills::SkillSource.new(id:, root: root || @operator, trust:)]
    ).compile
  end

  def toolbox(skills: Skills::Snapshot.empty, **options)
    Toolbox.new(root: @workspace, skills:, **options)
  end

  # ------------------------------------------------------- C-1 compatibility --

  def test_a_skill_free_toolbox_is_byte_identical_to_the_pre_p9_surface
    assert_equal PRE_P9_READ_ONLY_DIGEST, toolbox.catalog_digest
    assert_equal PRE_P9_READ_WRITE_DIGEST,
                 toolbox(allow_changes: true, checks: {"answer" => ["true"]}).catalog_digest
    assert_equal %w[read_file list_directory search_text], toolbox.names
    assert_equal %w[read_file list_directory search_text], toolbox.read_only_names
    assert_equal "none", toolbox.skill_epoch
  end

  # The other half of C-1: adding two tools IS a capability-surface change and
  # must be visible. An invisible expansion is what invariant 16 prevents.
  def test_a_skill_bearing_toolbox_changes_the_tool_surface_visibly
    write_skill("fix-answer")
    with_skills = toolbox(skills: snapshot)

    assert_includes with_skills.names, "load_skill"
    assert_includes with_skills.names, "read_skill_resource"
    refute_equal PRE_P9_READ_ONLY_DIGEST, with_skills.catalog_digest,
                 "a two-tool expansion must not be invisible to the pinned digest"
    assert_includes with_skills.read_only_names, "load_skill"
  end

  # And the complement: a catalog change with an identical tool set must still be
  # a visible epoch change, which is what prompt_surface_digest exists for.
  def test_prompt_surface_digest_tracks_the_catalog_when_the_tool_set_is_equal
    write_skill("fix-answer")
    first = toolbox(skills: snapshot)

    write_skill("fix-answer", body: "Rewritten instructions.\n")
    second = toolbox(skills: snapshot)

    assert_equal first.catalog_digest, second.catalog_digest, "the tool set did not change"
    refute_equal first.prompt_surface_digest, second.prompt_surface_digest
    refute_equal first.skill_epoch, second.skill_epoch
    assert_equal first.prompt_surface_digest, toolbox(skills: first.skills).prompt_surface_digest
  end

  def test_skill_tools_never_require_approval_and_declare_no_effect_output
    write_skill("fix-answer")
    box = toolbox(skills: snapshot, allow_changes: true, checks: {"answer" => ["true"]})

    refute box.approval_required?("load_skill")
    refute box.approval_required?("read_skill_resource")
    assert_equal 0, box.maximum_effect_output_bytes("load_skill")
    assert_equal 0, box.maximum_effect_output_bytes("read_skill_resource")
    refute_includes Tamoz::Evals::Harness::AgentRunAudit::EFFECT_TOOLS, "load_skill"
  end

  def test_the_snapshot_argument_is_configuration_not_a_tool_result
    assert_raises(ArgumentError) { toolbox(skills: {}) }
    assert_raises(ArgumentError) { toolbox(skills: nil) }
  end

  # --------------------------------------------------- H-4: profile isolation --

  # A P8 profile's tools.allowed is a closed list that cannot name a skill tool,
  # so a profile-bound toolbox is skill-free by construction. Fail-closed and
  # deliberate for this run; lifted by P9-B2 after P8-E.
  def test_a32_a_profile_bound_toolbox_exposes_no_skill_tool
    write_skill("fix-answer")
    refute_includes Tamoz::Agent::Profile::KNOWN_TOOLS, "load_skill"
    refute_includes Tamoz::Agent::Profile::KNOWN_TOOLS, "read_skill_resource"

    box = toolbox(skills: snapshot, allowed_tools: %w[read_file list_directory search_text])

    refute_includes box.names, "load_skill"
    refute_includes box.names, "read_skill_resource"
    assert_equal PRE_P9_READ_ONLY_DIGEST, box.catalog_digest
    assert_raises(Tamoz::Agent::ToolError) { box.validate("load_skill", "skill" => "fix-answer") }
  end

  # ------------------------------------------------------------- the two tools --

  def test_load_skill_returns_attributed_bounded_identity_bound_text
    write_skill("fix-answer", resources: {"references/how.md" => "Step one.\n", "scripts/x.rb" => "puts 1\n"})
    snap = snapshot
    box = toolbox(skills: snap, allow_changes: true, checks: {"answer" => ["true"]})
    output = box.execute("load_skill", "skill" => "fix-answer")
    record = snap.records.fetch("operator/fix-answer")

    assert_includes output, "Skill: operator/fix-answer"
    assert_includes output, "tree_digest: #{record.tree_digest}"
    assert_includes output, "declared-risk: guarded (author-declared; not a Tamoz classification)"
    assert_includes output, "UNTRUSTED SKILL CONTENT"
    assert_includes output, "Read broken.rb, then patch it."
    assert_includes output, "references/how.md (10 bytes)"
    assert_includes output, "scripts/x.rb (8 bytes, not readable)"
    refute_includes output, @dir, "no absolute path may reach a model-facing surface"
  end

  # `effective_tools` tells the model the truth about the intersection
  # (SKILLS_DESIGN §2). It is display; it is never written back.
  def test_load_skill_reports_the_honest_intersection_and_widens_nothing
    write_skill(
      "greedy",
      frontmatter: <<~YAML
        name: greedy
        description: demands everything
        allowed-tools: [read_file, apply_patch, run_check, shell, sudo]
      YAML
    )
    snap = snapshot
    read_only = toolbox(skills: snap)
    output = read_only.execute("load_skill", "skill" => "greedy")

    assert_includes output, "requested_capabilities: apply_patch, read_file, run_check, shell, sudo"
    assert_includes output, "effective_tools: read_file"
    refute_includes read_only.names, "shell"
    refute_includes read_only.names, "apply_patch"
    refute read_only.action_capable?

    full = toolbox(skills: snap, allow_changes: true, checks: {"answer" => ["true"]})

    assert_includes full.execute("load_skill", "skill" => "greedy"),
                    "effective_tools: apply_patch, read_file, run_check"
    refute_includes full.names, "shell"
    refute_includes full.names, "sudo"
  end

  def test_read_skill_resource_verifies_the_pinned_digest_at_execution_time
    write_skill("fix-answer", resources: {"references/how.md" => "Step one.\n"})
    box = toolbox(skills: snapshot)
    output = box.execute("read_skill_resource", "skill" => "fix-answer", "path" => "references/how.md")

    assert_includes output, "Skill resource: operator/fix-answer/references/how.md"
    assert_includes output, "Step one."
    assert_includes output, "UNTRUSTED SKILL CONTENT"

    File.write(File.join(@operator, "fix-answer", "references", "how.md"), "swapped\n")
    error = assert_raises(Tamoz::Agent::ToolError) do
      box.execute("read_skill_resource", "skill" => "fix-answer", "path" => "references/how.md")
    end

    assert_match(/\Askill_resource_changed:/, error.message)
  end

  # Invariant 17: an unknown or unreadable resource is a *plan review* issue, not
  # a surprise at execution time.
  def test_validation_rejects_unknown_ambiguous_and_unreadable_references
    write_skill("fix-answer", resources: {"scripts/x.rb" => "puts 1\n"})
    box = toolbox(skills: snapshot)

    [
      ["load_skill", {"skill" => "absent"}, /\Askill_unknown:/],
      ["load_skill", {"skill" => "operator/absent"}, /\Askill_unknown:/],
      ["load_skill", {"skill" => 42}, /skill must be a string/],
      ["load_skill", {"skill" => "fix-answer", "extra" => 1}, /unknown tool arguments/],
      ["read_skill_resource", {"skill" => "fix-answer", "path" => "nope.md"}, /\Askill_resource_unknown:/],
      ["read_skill_resource", {"skill" => "fix-answer", "path" => "../SKILL.md"}, /\Askill_resource_unknown:/],
      ["read_skill_resource", {"skill" => "fix-answer", "path" => "scripts/x.rb"}, /\Askill_resource_not_readable:/],
      ["read_skill_resource", {"skill" => "fix-answer", "path" => 7}, /path must be a string/]
    ].each do |tool, arguments, pattern|
      error = assert_raises(Tamoz::Agent::ToolError) { box.validate(tool, arguments) }

      assert_match pattern, error.message, "#{tool} #{arguments.inspect}"
    end
  end

  def test_an_ambiguous_bare_name_is_a_typed_validation_error
    workspace_source = File.join(@dir, "repo-skills")
    FileUtils.mkdir_p(workspace_source)
    write_skill("helper")
    write_skill("helper", root: workspace_source, body: "Impostor.\n")
    snap = Skills::Compiler.new(
      sources: [
        Skills::SkillSource.new(id: "operator", root: @operator, trust: "operator"),
        Skills::SkillSource.new(id: "repo", root: workspace_source, trust: "workspace")
      ]
    ).compile
    box = toolbox(skills: snap)
    error = assert_raises(Tamoz::Agent::ToolError) { box.validate("load_skill", "skill" => "helper") }

    assert_match(/\Askill_name_ambiguous:/, error.message)
    assert_includes box.execute("load_skill", "skill" => "operator/helper"), "operator/helper"
    assert_includes box.execute("load_skill", "skill" => "repo/helper"), "repo/helper"
  end

  # ----------------------------------------------------------- planning prompt --

  def test_a_skill_free_planning_prompt_is_byte_identical_to_the_pre_p9_prompt
    box = toolbox
    prompt = Tamoz::Agent::Deliberation.planning_prompt(
      "task", :read_only, box.names, [], [], {}, toolbox: box
    )

    refute_includes prompt, "skills"
    assert_equal prompt, Tamoz::Agent::Deliberation.planning_prompt(
      "task", :read_only, box.names, [], [], {}, toolbox: toolbox
    )
  end

  def test_the_catalog_enters_the_planning_prompt_with_explicit_truncation
    10.times { |index| write_skill(format("skill-%02d", index)) }
    box = toolbox(skills: snapshot)
    prompt = Tamoz::Agent::Deliberation.planning_prompt(
      "task", :discovery, box.names, [], [], {}, toolbox: box
    )

    assert_includes prompt, "operator/skill-00"
    assert_includes prompt, "author-supplied evidence"
    assert_includes prompt, "load_skill"
    refute_includes prompt, @dir
    assert_equal prompt, Tamoz::Agent::Deliberation.planning_prompt(
      "task", :discovery, box.names, [], [], {}, toolbox: box
    )
  end

  # --------------------------------------------------------- durable binding --

  def test_a_session_record_pins_the_skill_epoch_and_prompt_surface
    write_skill("fix-answer")
    box = toolbox(skills: snapshot)
    record = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "t1", task: "x", task_digest: "d", root: @workspace,
      graph_version: "1", behavior_version: "1",
      tool_catalog_digest: box.catalog_digest, created_at_ms: 0,
      skill_epoch: box.skill_epoch, prompt_surface_digest: box.prompt_surface_digest
    )

    assert_equal box.skill_epoch, record.fetch("skill_epoch")
    assert_equal box.prompt_surface_digest, record.fetch("prompt_surface_digest")
  end

  def test_a_pre_p9_session_record_loads_with_the_shared_empty_epoch
    legacy = {
      "record" => "session", "record_version" => 1, "session_id" => "t1", "task" => "x",
      "task_digest" => "d", "root" => @workspace, "graph_version" => "1",
      "behavior_version" => "1", "tool_catalog_digest" => "sha256:#{"0" * 64}",
      "created_at_ms" => 0
    }
    loaded = Tamoz::Agent::SessionRecords.load!(legacy, kind: "session")

    assert_equal "none", loaded.fetch("skill_epoch")
    assert_equal "legacy:none", loaded.fetch("prompt_surface_digest")
    assert_equal "legacy", loaded.fetch("profile_id")
    # A pre-P9 record and a new skill-free toolbox must agree, or every existing
    # durable session would stop on resume.
    assert_equal toolbox.skill_epoch, loaded.fetch("skill_epoch")
  end

  def test_resume_stops_when_the_skill_epoch_changed_and_proceeds_when_it_did_not
    write_skill("fix-answer")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(@dir, "sessions.sqlite3"))
    model = Object.new
    def model.generate(**) = "{}"

    begin
      original = toolbox(skills: snapshot)
      session = Tamoz::Agent::Session.new(model:, toolbox: original, checkpointer: adapter)
      seed_session_record(session, "t1", original)

      # Same epoch: resume proceeds.
      Tamoz::Agent::Session.new(
        model:, toolbox: toolbox(skills: original.skills), checkpointer: adapter
      ).verify_skill_binding!(thread: "t1")

      write_skill("fix-answer", body: "Rewritten instructions.\n")
      changed = Tamoz::Agent::Session.new(model:, toolbox: toolbox(skills: snapshot), checkpointer: adapter)
      error = assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        changed.verify_skill_binding!(thread: "t1")
      end

      assert_match(/was planned against skill epoch/, error.message)

      # A skill-free toolbox must not silently continue a skill-bearing session.
      removed = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter)

      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        removed.verify_skill_binding!(thread: "t1")
      end
    ensure
      adapter.close
    end
  end

  def test_a_legacy_session_resumes_against_a_skill_free_toolbox
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(@dir, "legacy.sqlite3"))
    model = Object.new
    def model.generate(**) = "{}"

    begin
      box = toolbox
      session = Tamoz::Agent::Session.new(model:, toolbox: box, checkpointer: adapter)
      seed_session_record(session, "legacy-thread", box)

      # No exception: "none" == "none".
      assert_nil session.verify_skill_binding!(thread: "legacy-thread")
    ensure
      adapter.close
    end
  end

  def test_verify_skill_binding_is_silent_for_an_unknown_thread
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(@dir, "unknown.sqlite3"))
    model = Object.new
    def model.generate(**) = "{}"

    begin
      session = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter)

      assert_nil session.verify_skill_binding!(thread: "never-seen")
    ensure
      adapter.close
    end
  end

  private

  # Writes the intake session record for `thread` directly through the durable
  # runner, so the resume guard reads a real checkpoint rather than a stub.
  def seed_session_record(session, thread, box)
    session.app.durable_runner.checkpointer.put(
      thread_id: thread,
      ns: "",
      checkpoint: {
        state: {
          session: Tamoz::Agent::SessionRecords.build(
            "session",
            session_id: thread, task: "x", task_digest: "d", root: @workspace,
            graph_version: Tamoz::Agent::Session::GRAPH_VERSION,
            behavior_version: "1", tool_catalog_digest: box.catalog_digest,
            created_at_ms: 0, skill_epoch: box.skill_epoch,
            prompt_surface_digest: box.prompt_surface_digest
          )
        }
      }
    )
  end
end
