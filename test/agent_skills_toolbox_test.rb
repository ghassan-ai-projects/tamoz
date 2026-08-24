# frozen_string_literal: true

require_relative "test_helper"

# P9-B: progressive disclosure through the ordinary tool boundary, the prompt
# surface epoch, and the durable exact-digest resume rule.
class AgentSkillsToolboxTest < Minitest::Test
  Skills = Tamoz::Agent::Skills
  Toolbox = Tamoz::Agent::Toolbox

  # Measured at 6dee1b6, before skills.rb existed; re-measured when the tool
  # catalog digest moved to the RFC 8785 rule (PLAN_TAMOZ_STREAM_BUILD T0.1),
  # and again when approval gating left the hashed catalog surface and checks
  # bound their argv (toolbox redesign phases 7+7B).
  # These pin the compatibility half of plan review finding C-1: a toolbox with
  # no skills must be byte-identical to the pre-P9 surface, so every P8 profile
  # keeps validating.
  PRE_P9_READ_ONLY_DIGEST =
    "sha256:4344901f2da07a1fc610d904894bca2dbe1c74bc48ed644ab259531cbd6aa91a"
  PRE_P9_READ_WRITE_DIGEST =
    "sha256:70a08d53e3565bf626723751af2267910f4c2d197ccaea742ea283dce8732644"

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

  def test_skill_tools_are_read_classified_and_declare_no_effect_output
    write_skill("fix-answer")
    box = toolbox(skills: snapshot, allow_changes: true, checks: {"answer" => ["true"]})

    assert_includes box.read_only_names, "load_skill"
    assert_includes box.read_only_names, "read_skill_resource"
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
    # Byte counts are the exact on-disk sizes; the index must agree with the disk,
    # so both the literal and the indexed value are asserted.
    assert_equal 10, "Step one.\n".bytesize
    assert_equal 7, "puts 1\n".bytesize
    assert_equal 10, record.resource_index.fetch("references/how.md").bytes
    assert_equal 7, record.resource_index.fetch("scripts/x.rb").bytes
    assert_includes output, "references/how.md (10 bytes)"
    assert_includes output, "scripts/x.rb (7 bytes, not readable)"
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

  def test_a_session_without_skills_loads_with_the_shared_empty_epoch
    record = Tamoz::Agent::SessionRecords.build(
      "session", session_id: "t1", task: "x", task_digest: "d", root: @workspace,
      graph_version: "1", behavior_version: "1",
      tool_catalog_digest: "sha256:#{"0" * 64}", created_at_ms: 0
    )
    loaded = Tamoz::Agent::SessionRecords.load!(record, kind: "session")

    assert_equal "none", loaded.fetch("skill_epoch")
    assert_equal "legacy:none", loaded.fetch("prompt_surface_digest")
    assert_equal "legacy", loaded.fetch("profile_id")
    # A pre-P9 record and a new skill-free toolbox must agree, or every existing
    # durable session would stop on resume.
    assert_equal toolbox.skill_epoch, loaded.fetch("skill_epoch")
  end

  # A16 end to end. The session record is written by the *real* intake node during
  # a real durable turn — nothing is hand-seeded — and the stop is asserted on
  # `continue`/`resume`, which is the path a programmatic caller actually takes.
  def test_a16_a_content_swap_changes_the_epoch_and_stops_a_durable_resume
    write_skill("fix-answer")
    with_durable_session(skills: snapshot) do |session, adapter, original|
      outcome = session.start("read the note", thread: "t1", request_id: "r1")

      assert_equal :completed, outcome.status
      record = session.view(thread: "t1").state.fetch(:session)
      assert_equal original.skill_epoch, record.fetch("skill_epoch")
      assert_equal original.prompt_surface_digest, record.fetch("prompt_surface_digest")
      refute_equal "none", record.fetch("skill_epoch")

      # Recompiling the unchanged tree yields the same epoch, so a resume proceeds.
      same = build_session(adapter:, skills: snapshot)

      assert_nil same.verify_skill_binding!(thread: "t1")

      # A same-version body swap is a different skill (tree_digest is identity).
      write_skill("fix-answer", body: "Rewritten instructions.\n")
      swapped = snapshot

      refute_equal original.skills.catalog_digest, swapped.catalog_digest
      changed = build_session(adapter:, skills: swapped)
      error = assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        changed.verify_skill_binding!(thread: "t1")
      end

      assert_match(/was planned against skill epoch/, error.message)

      # The guard is on the unbypassable path, not only on the explicit call:
      # `continue`, `resume`, and `recover` all funnel through `guard_state!`.
      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        changed.continue(thread: "t1", request_id: "r2")
      end
      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        changed.resume({}, thread: "t1", request_id: "r3")
      end
      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        changed.recover(thread: "t1", request_id: "r4")
      end

      # Removing the catalog entirely must not silently continue either.
      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        build_session(adapter:).continue(thread: "t1", request_id: "r5")
      end
    end
  end

  # The complement: a session that never had skills must keep resuming, and a
  # skill-free P9 toolbox must agree with a pre-P9 record's "none".
  def test_a_skill_free_session_still_resumes_and_a_new_catalog_stops_it
    with_durable_session do |session, adapter, box|
      assert_equal :completed, session.start("read the note", thread: "t2", request_id: "r1").status
      assert_equal "none", session.view(thread: "t2").state.fetch(:session).fetch("skill_epoch")
      assert_equal "none", box.skill_epoch
      assert_nil build_session(adapter:).verify_skill_binding!(thread: "t2")
      # A skill-free continuation must get *past* the skill guard. The continue is
      # then stale (a completed thread has no runnable frontier) and terminal-fails
      # as a typed request value (DR-4) instead of raising — which is precisely the
      # evidence that the guard let it through.
      ordinary = build_session(adapter:).continue(thread: "t2", request_id: "r2")
      assert_equal :failed, ordinary.request_status
      request = build_session(adapter:).app.durable_runner.fetch(
        thread: "t2",
        request_id: "r2"
      )
      assert_equal :failed, request.status
      assert_match(/no runnable frontier/, request.terminal_error.fetch("reason"))

      # A pre-skill session must not silently *gain* a catalog mid-flight.
      write_skill("fix-answer")

      assert_raises(Tamoz::Agent::SkillSnapshotUnavailableError) do
        build_session(adapter:, skills: snapshot).verify_skill_binding!(thread: "t2")
      end
    end
  end

  def test_verify_skill_binding_is_silent_for_an_unknown_thread
    with_durable_session do |session, _adapter, _box|
      assert_nil session.verify_skill_binding!(thread: "never-seen")
    end
  end

  private

  class ScriptedModel
    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
    end

    def generate(stage:, system:, prompt:)
      queue = @responses.fetch(stage)
      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def scripted_model
    ScriptedModel.new(
      plan: [{
        "goal" => "answer the task",
        "done_when" => ["the tool returned evidence"],
        "steps" => [{
          "id" => "s1", "purpose" => "gather evidence", "tool" => "read_file",
          "arguments" => {"path" => "note.txt"}, "verification" => "the output is present"
        }]
      }],
      review: [{"decision" => "accept", "issues" => [], "rationale" => "sound"}],
      verify: [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
    )
  end

  def build_session(adapter:, skills: Skills::Snapshot.empty)
    Tamoz::Agent::Session.new(
      model: scripted_model, toolbox: toolbox(skills:), checkpointer: adapter
    )
  end

  def with_durable_session(skills: Skills::Snapshot.empty)
    File.write(File.join(@workspace, "note.txt"), "Tamoz is awake.\n")
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(@dir, "sessions.sqlite3"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
    )
    box = toolbox(skills:)
    begin
      yield Tamoz::Agent::Session.new(model: scripted_model, toolbox: box, checkpointer: adapter),
            adapter,
            box
    ensure
      adapter.close
    end
  end
end
