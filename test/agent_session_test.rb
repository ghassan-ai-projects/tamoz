# frozen_string_literal: true

require_relative "test_helper"

class AgentSessionTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def test_session_requires_a_durable_checkpointer
    error = assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::Session.new(
        model: ScriptedModel.new,
        toolbox: Tamoz::Agent::Toolbox.new(root: Dir.tmpdir),
        checkpointer: Tamoz::Graph::MemoryCheckpointer.new
      )
    end

    assert_match(/durable checkpointer/, error.message)
  end

  def test_read_only_session_plans_reviews_executes_and_verifies_durably
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      session = build_session(model:, root:, adapter:)

      outcome = session.start(
        "What does note.txt say?",
        thread: "session.read",
        request_id: "request.1"
      )

      assert_equal :completed, outcome.status
      assert_equal :completed, outcome.request_status
      assert outcome.result.satisfied
      assert_equal "Tamoz is awake.", outcome.result.answer
      assert_equal %i[plan review verify], model.calls.map { |call| call.fetch(:stage) }

      view = session.view(thread: "session.read")
      assert_equal "terminal", view.phase
      assert_equal 1, view.state.fetch(:plan_versions).length
      assert_equal 2, view.state.fetch(:plan_reviews).length
      assert_equal(
        view.accepted_plan.fetch("plan_digest"),
        view.state.fetch(:plan_versions).first.fetch("plan_digest")
      )
      assert_equal 1, view.effect_receipts.length
      assert_equal "tool.read_file", view.effect_receipts.first.fetch("operation")
      assert_equal "read_only", view.effect_receipts.first.fetch("safety")
      assert adapter.integrity_check.fetch("ok")
    end
  end

  # A channel turn carries the conversation transcript nested in its task
  # payload (the comms gateway puts it there); the planner AND the reviewer
  # must both see it, or a follow-up like "and the font?" is reviewed as if
  # it stood alone.
  def test_a_turn_with_a_conversation_payload_plans_and_reviews_with_the_transcript
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "blue\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "blue", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      session = build_session(model:, root:, adapter:)

      request = session.app.durable_runner.deliver(
        Tamoz::Agent::SessionPlanningContext.turn_payload(
          thread_id: "session.conversation",
          request_id: "request.1",
          text: "and the font?",
          fragments: [
            {"role" => "user", "text" => "make it blue"},
            {"role" => "assistant", "text" => "done, it is blue"}
          ]
        ),
        thread: "session.conversation",
        request_id: "request.1"
      )

      assert_equal :completed, request.status
      assert_equal "and the font?",
                   session.view(thread: "session.conversation").state.fetch(:task),
                   'the state channel keeps the bare text, not the payload Hash'
      %i[plan review].each do |stage|
        prompt = model.calls.find { |call| call.fetch(:stage) == stage }.fetch(:prompt)
        assert_includes prompt, "make it blue", "the #{stage} prompt must see the transcript"
        assert_includes prompt, "done, it is blue", "the #{stage} prompt must see the transcript"
      end
    end
  end

  def test_profile_bound_session_records_profile_identity
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      toolbox = Tamoz::Agent::Toolbox.new(root:)
      profile = build_profile(root:, catalog_digest: toolbox.catalog_digest)
      session = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter, profile:)

      outcome = session.start("What does note.txt say?", thread: "session.profile", request_id: "request.1")

      assert_equal :completed, outcome.status
      record = session.view(thread: "session.profile").state.fetch(:session)
      assert_equal "test-profile", record.fetch("profile_id")
      assert_equal profile.canonical_digest, record.fetch("profile_digest")
    end
  end

  def test_profile_catalog_mismatch_fails_before_model_io
    with_workspace do |root, adapter|
      model = ScriptedModel.new(plan: [], review: [], verify: [])
      toolbox = Tamoz::Agent::Toolbox.new(root:)
      profile = build_profile(root:, catalog_digest: "sha256:#{"0" * 64}")
      error = assert_raises(Tamoz::Agent::Profile::ValidationError) do
        Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter, profile:)
      end
      assert_match(/tool_catalog_digest/, error.message)
      assert_empty model.calls
    end
  end

  def test_duplicate_request_id_does_not_start_a_second_turn
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "one\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "one", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      session = build_session(model:, root:, adapter:)

      first = session.start("read it", thread: "session.dup", request_id: "request.dup")
      calls = model.calls.length
      second = session.start("read it", thread: "session.dup", request_id: "request.dup")

      assert_equal :completed, first.status
      assert_equal :completed, second.request_status
      assert_equal calls, model.calls.length
      assert_equal 1, session.app.history(thread: "session.dup", limit: 100)
                              .map(&:execution_id).uniq.length
    end
  end

  def test_action_session_pauses_for_approval_and_applies_one_reviewed_effect
    with_workspace do |root, adapter|
      target = File.join(root, "app.rb")
      File.write(target, "value = 1\n")
      digest = Digest::SHA256.hexdigest(File.read(target))
      session = build_session(
        model: repair_model(digest),
        root:,
        adapter:,
        allow_changes: true,
        checks: {"answer" => check_argv}
      )

      paused = session.start(
        "set value to 2",
        thread: "session.act",
        request_id: "request.act"
      )

      assert_equal :paused, paused.status
      assert_equal 1, paused.approvals.length
      descriptor = paused.approvals.first
      assert_equal "apply_patch", descriptor.fetch("tool")
      assert_includes descriptor.fetch("preview"), "+value = 2"
      assert_equal "value = 1\n", File.read(target), "no effect before approval"

      completed = approve_all(session, paused, thread: "session.act", request_id: "request.act.1")

      assert_equal :completed, completed.status
      assert_equal "value = 2\n", File.read(target)
      view = session.view(thread: "session.act")
      assert_equal 2, view.approvals.length
      assert(view.approvals.all? { |record| record.fetch("decision") == "approve" })
      receipts = view.effect_receipts.map { |record| record.fetch("operation") }
      assert_includes receipts, "tool.apply_patch"
      assert_includes receipts, "tool.run_check"
      assert view.state.fetch(:check_passed)
      assert view.terminal.fetch("satisfied")
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_denied_approval_stops_before_any_filesystem_effect
    with_workspace do |root, adapter|
      target = File.join(root, "app.rb")
      File.write(target, "value = 1\n")
      digest = Digest::SHA256.hexdigest(File.read(target))
      session = build_session(
        model: repair_model(digest),
        root:,
        adapter:,
        allow_changes: true,
        checks: {"answer" => check_argv}
      )

      paused = session.start(
        "set value to 2",
        thread: "session.deny",
        request_id: "request.deny"
      )
      denied = session.resume(
        {paused_task_id(session, "session.deny") => {0 => false}},
        thread: "session.deny",
        request_id: "request.deny.1"
      )

      assert_equal :completed, denied.status
      assert_equal "value = 1\n", File.read(target)
      view = session.view(thread: "session.deny")
      assert_equal "deny", view.approvals.first.fetch("decision")
      assert_equal "approval_denied", view.terminal.fetch("reason")
      assert_empty view.effect_receipts.select { |r| r.fetch("operation") == "tool.apply_patch" }
    end
  end

  def test_an_interrupt_terminates_its_request_and_resume_is_a_new_request
    with_workspace do |root, adapter|
      target = File.join(root, "app.rb")
      File.write(target, "value = 1\n")
      digest = Digest::SHA256.hexdigest(File.read(target))
      session = build_session(
        model: repair_model(digest),
        root:,
        adapter:,
        allow_changes: true,
        checks: {"answer" => check_argv}
      )

      paused = session.start("set value to 2", thread: "session.req", request_id: "request.a")
      assert_equal :paused, paused.status
      assert_equal :completed, paused.request_status, "a pause terminates its own request"

      approve_all(session, paused, thread: "session.req", request_id: "request.b")
      first = session.app.durable_runner.fetch(thread: "session.req", request_id: "request.a")
      second = session.app.durable_runner.fetch(thread: "session.req", request_id: "request.b.1")

      refute_equal first.request_id, second.request_id
      assert_equal :turn, first.operation
      assert_equal :resume, second.operation
      assert_operator second.enqueue_sequence, :>, first.enqueue_sequence
    end
  end

  def test_unsupported_newer_record_version_fails_before_any_node_runs
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "one\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "one", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      session = build_session(model:, root:, adapter:)
      session.start("read it", thread: "session.version", request_id: "request.v")
      calls = model.calls.length

      append_future_version_checkpoint(session, "session.version")

      error = assert_raises(Tamoz::CheckpointVersionError) do
        session.continue(thread: "session.version", request_id: "request.v2")
      end

    assert_match(/version 3 exceeds supported version 2/, error.message)
      assert_equal calls, model.calls.length, "no node ran"
    end
  end

  def test_sensitive_values_are_rejected_from_session_records
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz::Agent::SessionRecords.reject_sensitive!(
        {"a" => [{"b" => Tamoz::Secret.new("token")}]}
      )
    end
  end

  private

  def with_workspace
    Dir.mktmpdir("tamoz-session") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def build_session(model:, root:, adapter:, allow_changes: false, checks: {}, **options)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes:, checks:),
      checkpointer: adapter,
      **options
    )
  end

  def approve_all(session, outcome, thread:, request_id:, limit: 8)
    current = outcome
    index = 0
    while current.status == :paused && index < limit
      index += 1
      current = session.resume(
        {paused_task_id(session, thread) => {0 => true}},
        thread:,
        request_id: "#{request_id}.#{index}"
      )
    end
    current
  end

  def paused_task_id(session, thread)
    session.view(thread:).interrupts.first.task_id
  end

  def check_argv
    [RbConfig.ruby, "-e", %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}]
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {
          "id" => id,
          "purpose" => "gather evidence",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "the output is present"
        }
      ]
    }
  end

  def repair_model(digest)
    action = {
      "goal" => "set value to 2",
      "done_when" => ["app.rb contains value = 2 and the check passes"],
      "steps" => [
        {
          "id" => "edit",
          "purpose" => "apply the exact replacement",
          "tool" => "apply_patch",
          "arguments" => {
            "path" => "app.rb",
            "expected_sha256" => digest,
            "before" => "value = 1",
            "after" => "value = 2"
          },
          "verification" => "the receipt reports the new digest"
        },
        {
          "id" => "check",
          "purpose" => "run the configured check",
          "tool" => "run_check",
          "arguments" => {"name" => "answer"},
          "verification" => "the check exits zero"
        }
      ]
    }
    ScriptedModel.new(
      plan: [plan_for("read_file", {"path" => "app.rb"}, id: "look"), action],
      review: [accepted_review],
      verify: [{"answer" => "value is 2", "satisfied" => true, "evidence" => ["app.rb"]}]
    )
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end

  # Writes a *validly digested* checkpoint whose state contains a record from a
  # hypothetical future format version, exactly as a newer process would have left it.
  # Byte-editing the payload would only prove the payload digest guard.
  def append_future_version_checkpoint(session, thread)
    store = session.app.checkpointer
    store.open_writer(
      thread_id: thread,
      namespace: [],
      owner_id: "test.future",
      ttl: store.writer_ttl
    ) do |writer|
      latest = writer.latest
      future = {
        "record" => "plan",
        "record_version" => 3,
        "plan_id" => "future.0.1",
        "phase" => "action",
        "attempt" => 1,
        "plan" => {"goal" => "future", "done_when" => [], "steps" => []},
        "plan_digest" => "0" * 64
      }
      state = latest.state.merge(
        plan_versions: latest.state.fetch(:plan_versions) + [future]
      )
      session.app.__send__(
        :append_checkpoint,
        writer:,
        thread:,
        namespace: [],
        expected_base_id: latest.id,
        mode: :advance,
        execution_id: latest.execution_id,
        state:,
        status: :running,
        logical_step: latest.logical_step,
        frontier: latest.frontier,
        pending: {},
        interrupts: [],
        resume_values: {},
        attempts: latest.attempts,
        failure: nil,
        total_tasks: latest.total_tasks
      )
    end
  end

  def build_profile(root:, catalog_digest:, digest: "sha256:#{"d" * 64}")
    Tamoz::Agent::Profile.new(
      Tamoz::Agent::Profile::Fields.new(
        profile_id: "test-profile",
        profile_version: "1.0",
        canonical_root: File.expand_path(root),
        description: nil,
        model_roles: {},
        budgets: {},
        checks: {},
        tools_allowed: %w[read_file list_directory search_text],
        tools_approval_required: [],
        policy: {
          "allow_changes" => false,
          "default_check_safety" => "unsafe",
          "graph_version" => "1",
          "behavior_version" => "1.0",
          "tool_catalog_digest" => catalog_digest
        },
        canonical_digest: digest,
        suggestion: false
      )
    )
  end
end
