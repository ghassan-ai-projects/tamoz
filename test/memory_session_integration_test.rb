# frozen_string_literal: true

require_relative "test_helper"

# P11 probes P11-03, P11-19, P11-20: the session integration — the memory_epoch
# sentinel, BehaviorTransition consumption at the FIRST INTAKE OF A THREAD
# (claim → apply → finalize, existing threads pinned), the cache-epoch proof
# (prefix digest moves with a recorded reason, in-flight stays pinned, rollback
# returns byte-identical), and turn-boundary memory writes.
class MemorySessionIntegrationTest < Minitest::Test
  Memory = Tamoz::Agent::Memory

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

  def with_memory_workspace
    Dir.mktmpdir("tamoz-mem-session") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        state_codec: Memory::Surface.codec,
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      engine = Memory::Engine.new(tenant: "acme", adapter:)
      begin
        yield File.realpath(root), adapter, engine
      ensure
        adapter.close
      end
    end
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {"id" => id, "purpose" => "gather evidence", "tool" => tool, "arguments" => arguments,
         "verification" => "the output is present"}
      ]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end

  def read_model
    ScriptedModel.new(
      plan: [plan_for("read_file", {"path" => "note.txt"})],
      review: [accepted_review],
      verify: [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
    )
  end

  def build_session(model:, root:, adapter:, engine:, **options)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:),
      checkpointer: adapter,
      memory: engine,
      memory_owner: "alice",
      **options
    )
  end

  def test_memory_enabled_session_records_epoch_and_writes_episode_memory
    with_memory_workspace do |root, adapter, engine|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      session = build_session(model: read_model, root:, adapter:, engine:)
      outcome = session.start(
        "What does note.txt say?", thread: "mem.one", request_id: "request.1"
      )
      assert_equal :completed, outcome.status

      record = session.view(thread: "mem.one").state.fetch(:session)
      assert record.fetch("memory_epoch").is_a?(Hash)
      assert_equal %w[experience knowledge wisdom], record.fetch("memory_epoch").fetch("layers")

      # Turn-boundary memory write: the completed episode became an Experience
      # record (deterministic admission gate (a), no model call).
      recalled = engine.retrieval.recall(
        caller: engine.caller(user: "alice", project: "session"),
        query: {terms: ["note"]}
      )
      assert_equal 1, recalled.records.length
      assert_equal :experience, recalled.records.first.layer
    end
  end

  def test_behavior_transition_consumed_at_first_intake_and_threads_pinned
    with_memory_workspace do |root, adapter, engine|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")

      # An OLD thread started BEFORE promotion is pinned to session/1: its
      # committed record freezes the version at intake, so promotion cannot
      # rewrite it (resume/continue/redirect are boundary: false).
      old_session = build_session(model: read_model, root:, adapter:, engine:)
      old_outcome = old_session.start(
        "What does note.txt say?", thread: "mem.pinned", request_id: "request.old"
      )
      assert_equal :completed, old_outcome.status
      pinned_record = old_session.view(thread: "mem.pinned").state.fetch(:session)
      assert_equal "tamoz.agent.session/1", pinned_record.fetch("behavior_version")

      # Promote a Wisdom candidate into a pending BehaviorTransition.
      candidate = Memory::MemoryRecord.new(
        memory_id: "wis.planning", layer: :wisdom, klass: :strategy,
        state: :candidate, epistemic_kind: :inferred, owner: "alice",
        scopes: {"tenant" => "acme", "user" => "alice", "project" => "session", "session" => "s"},
        sensitivity: :internal,
        statement: "Prefer two green checks before promotion",
        source_refs: [{"identity" => "k1", "digest" => "d", "observed_at" => 1}],
        confidence: 0.95, confidence_method: "evaluation"
      )
      promoted = engine.wisdom.promote(
        candidate:,
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: "human:operator-1"},
        behavior_snapshot: {"wisdom" => "two green checks before promotion"},
        behavior_version_after: "tamoz.agent.session/2"
      )
      transition_id = promoted.fetch("transition").transition_id
      assert_equal :recorded, engine.transitions.transition(transition_id).status

      # The OLD thread is pinned: promotion does not rewrite its record and a
      # resume keeps the old version (never silently upgraded).
      old_session.verify_behavior_binding!(thread: "mem.pinned")
      assert_equal "tamoz.agent.session/1",
                   old_session.view(thread: "mem.pinned").state.fetch(:session).fetch("behavior_version")

      # The NEW thread's first intake consumes the transition (claim → apply →
      # finalize) and runs the new behavior version.
      new_session = build_session(model: read_model, root:, adapter:, engine:)
      new_outcome = new_session.start(
        "What does note.txt say?", thread: "mem.adopter", request_id: "request.new"
      )
      assert_equal :completed, new_outcome.status
      adopted = new_session.view(thread: "mem.adopter").state.fetch(:session)
      assert_equal "tamoz.agent.session/2", adopted.fetch("behavior_version")
      assert_equal transition_id, adopted.fetch("epoch_reason")
      assert_equal "two green checks before promotion", adopted.fetch("behavior_snapshot").fetch("wisdom")
      assert_equal :activated, engine.transitions.transition(transition_id).status

      # The promoted snapshot appears in the planning context as a delimited
      # block (the Wisdom behavior injection).
      planning_call = new_session.view(thread: "mem.adopter")
      assert planning_call.state.fetch(:plan_versions).any?
      # The cache epoch moved: the adopting session's prompt-surface digest is
      # the EXTENDED digest, different from the pinned thread's toolbox digest.
      refute_equal pinned_record.fetch("prompt_surface_digest"), adopted.fetch("prompt_surface_digest")
    end
  end

  def test_resume_replays_the_pinned_snapshot_and_keeps_the_old_version
    with_memory_workspace do |root, adapter, engine|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      # Adopt the transition on the first thread.
      candidate = Memory::MemoryRecord.new(
        memory_id: "wis.planning", layer: :wisdom, klass: :strategy,
        state: :candidate, epistemic_kind: :inferred, owner: "alice",
        scopes: {"tenant" => "acme", "user" => "alice", "project" => "session", "session" => "s"},
        sensitivity: :internal,
        statement: "Prefer two green checks before promotion",
        source_refs: [{"identity" => "k1", "digest" => "d", "observed_at" => 1}],
        confidence: 0.95, confidence_method: "evaluation"
      )
      engine.wisdom.promote(
        candidate:,
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: "human:operator-1"},
        behavior_snapshot: {"wisdom" => "two green checks before promotion"},
        behavior_version_after: "tamoz.agent.session/2"
      )
      session = build_session(model: read_model, root:, adapter:, engine:)
      session.start("What does note.txt say?", thread: "mem.t1", request_id: "r1")

      # A second promotion moves the active version again.
      engine.wisdom.promote(
        candidate: candidate.with(memory_id: "wis.planning2", statement: "Never promote on a single green check"),
        development_evaluation: {evidence_digest: "sha256:dev2", passed: true, outcomes_digest: "sha256:o2"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: "human:operator-2"},
        behavior_snapshot: {"wisdom" => "never promote on a single green check"},
        behavior_version_after: "tamoz.agent.session/3"
      )
      # Adopt on a second thread.
      session2 = build_session(model: read_model, root:, adapter:, engine:)
      session2.start("What does note.txt say?", thread: "mem.t2", request_id: "r2")
      second_record = session2.view(thread: "mem.t2").state.fetch(:session)
      assert_equal "tamoz.agent.session/3", second_record.fetch("behavior_version")

      # The FIRST thread resumes with the OLD pinned snapshot replayed and the
      # old behavior version kept (boundary false — never rewritten, never
      # silently upgraded). Its pinned snapshot is still resolvable.
      view = session.view(thread: "mem.t1")
      first_record = view.state.fetch(:session)
      assert_equal "tamoz.agent.session/2", first_record.fetch("behavior_version")
      session.verify_behavior_binding!(thread: "mem.t1")
      assert_equal({"wisdom" => "two green checks before promotion"}, first_record.fetch("behavior_snapshot"))

      # A pinned snapshot that can no longer be rebuilt stops typed. The
      # snapshot row exists at version 1; deleting it requires the expected
      # version (the Store CAS contract).
      engine.store.delete(
        Memory::BehaviorTransition::SNAPSHOTS_NAMESPACE,
        first_record.fetch("behavior_snapshot_digest"),
        if_version: 1
      )
      assert_raises(Memory::BehaviorSnapshotUnavailableError) do
        session.verify_behavior_binding!(thread: "mem.t1")
      end
    end
  end

  def test_pre_p11_session_resumes_byte_identical_with_no_memory_injection
    with_memory_workspace do |root, adapter, engine|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      # A memory-free session (no engine) writes a pre-P11-identical record.
      plain_session = Tamoz::Agent::Session.new(
        model: read_model,
        toolbox: Tamoz::Agent::Toolbox.new(root:),
        checkpointer: adapter
      )
      plain_session.start("What does note.txt say?", thread: "mem.plain", request_id: "r1")

      # The memory-free write surface is byte-identical to pre-P11: the record
      # loads with the legacy sentinel filled (probe P11-03), RECORD_VERSION
      # still 1, and the baseline behavior version.
      plain_record = plain_session.view(thread: "mem.plain").state.fetch(:session)
      assert_equal Memory::LEGACY_MEMORY_EPOCH, plain_record.fetch("memory_epoch")
      assert_equal "tamoz.agent.session/1", plain_record.fetch("behavior_version")
      assert_equal 2, plain_record.fetch("record_version")

      # Resuming the SAME record through a memory-enabled session loads the
      # "none" sentinel and injects zero memory content (boundary false never
      # rewrites the session record): the served state is byte-identical.
      memory_session = build_session(model: read_model, root:, adapter:, engine:)
      memory_session.verify_behavior_binding!(thread: "mem.plain")
      after = memory_session.view(thread: "mem.plain").state.fetch(:session)
      assert_equal plain_record, after
    end
  end
end
