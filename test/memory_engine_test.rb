# frozen_string_literal: true

require_relative "test_helper"

# P11 probes P11-01..P11-04, P11-10..P11-15, P11-16/17, P11-19..P11-21,
# P11-A1..A3: the agent-side memory surface — record/lifecycle, deterministic
# admission (reject matrix, no-model gate, owner fast path), retrieval policy
# (budget, trace, anti self-ingestion), correction/deletion with receipts,
# consolidation (preimage + gates), and the DR-1 BehaviorTransition machinery.
class MemoryEngineTest < Minitest::Test
  Memory = Tamoz::Agent::Memory

  class CountingProtection
    attr_reader :decrypts

    def initialize
      @decrypts = 0
    end

    def name = "test.counting.xor"

    def encrypt(bytes, context:)
      bytes.b.bytes.map { |byte| byte ^ 0x5A }.pack("C*")
    end

    def decrypt(bytes, context:)
      @decrypts += 1
      bytes.bytes.map { |byte| byte ^ 0x5A }.pack("C*")
    end
  end

  def setup
    @directory = Dir.mktmpdir("tamoz-memory-engine")
    @protection = CountingProtection.new
    @adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(@directory, "memory.db"),
      state_codec: Memory::Surface.codec,
      store_protection: @protection,
      limits: Tamoz::SQLite::Limits.new(deletion_retention: 86_400.0)
    )
    @clock = Time.at(1_700_000_000)
    @engine = Memory::Engine.new(
      tenant: "acme",
      adapter: @adapter,
      protection: @protection,
      clock: -> { @clock }
    )
  end

  def teardown
    @adapter.close if @adapter && !@adapter.closed?
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def scopes(user: "alice")
    {"tenant" => "acme", "user" => user, "project" => "proj", "session" => "s1"}
  end

  def caller(user: "alice")
    {
      tenant: "acme", user:, project: "proj",
      sensitivity: :internal,
      compatibility_graph: "1",
      compatibility_behavior: "tamoz.agent.session/1"
    }
  end

  # A durable effect context on the memory adapter so the consolidation model
  # call is journalled (P-01). Each invocation uses a fresh execution/thread.
  def with_consolidation_context
    @consolidation_seq = (@consolidation_seq || 0) + 1
    thread = "thread.consolidation.#{@consolidation_seq}"
    graph = Tamoz.graph(name: "consolidation-base", version: "1") do
      state :ready, default: false
      node(:finish, implementation_name: "consolidation.finish", version: "1") { |_state, _context| {ready: true} }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    app = graph.compile(checkpointer: @adapter)
    request = app.durable_runner.deliver({}, thread:, request_id: "request.#{@consolidation_seq}")
    store = app.checkpointer
    result = nil
    store.open_writer(thread_id: thread, namespace: [], owner_id: "consolidation.owner", ttl: store.writer_ttl) do |writer|
      context = Tamoz::Context.new(
        run_id: "run.#{@consolidation_seq}", execution_id: request.execution_id,
        request_id: "request.#{@consolidation_seq}", task_id: "task.consolidation", effects: writer.effects
      )
      result = yield context
    end
    result
  end

  def episode(statement: "Deploy canary first, then monitor", user: "alice", session_id: "s1", valid_until: nil)
    {
      session_id:,
      episode_id: "s1",
      attempt_id: "at-1",
      statement:,
      task: "rollout the deployment",
      plan_digest: "sha256:plan-#{statement}",
      completed_at: @clock.to_i,
      valid_until:,
      scopes: scopes(user:),
      sensitivity: :internal,
      decisions: ["canary 10%"],
      corrections: [],
      observed_outcome: {"outcome" => "deployment staged", "confidence" => 0.9}
    }
  end

  # T5.3: the authenticated reconciled-outcome reference that admits an
  # episode as :observed — the stream's reconciled Outcome is the independent
  # observer Tamoz alone cannot be.
  def reconciled_outcome(overrides = {})
    {
      "outcome_id" => "out-1",
      "outcome_digest" => "sha256:#{"c" * 64}",
      "command_id" => "cmd-1",
      "decision_id" => "decision-1",
      "source_authority" => "stream-1",
      "reconciliation_version" => 1,
      "observation_status" => "verified",
      "episode_id" => "s1",
      "attempt_id" => "at-1"
    }.merge(overrides)
  end

  def verify_source_authority
    lambda do |reference|
      reference.fetch("source_authority") == "stream-1"
    end
  end

  def admit_episode(statement: "Deploy canary first, then monitor", user: "alice")
    @engine.admission.admit_episode(
      episode: episode(statement:, user:),
      owner: user,
      reconciled_outcome: reconciled_outcome,
      verify_source_authority:
    )
  end

  def test_record_is_immutable_versioned_and_codec_registered
    # P11-01/P11-02: one immutable versioned MemoryRecord; the codec is in the
    # allowlist and an unknown format_version fails before partial load.
    result = admit_episode
    assert result.accepted?
    record = result.record
    assert record.frozen?
    assert_equal :experience, record.layer
    assert_equal :observed, record.epistemic_kind
    assert_equal 1, record.record_version
    assert record.transition.key?("actor")

    # Unknown format_version -> CheckpointVersionError before any field load.
    tampered = record.to_h.merge("format_version" => 2)
    assert_raises(Tamoz::CheckpointVersionError) do
      Memory::MemoryRecord.from_h(tampered)
    end

    # Three physical versions under tamoz.memory.<tenant>, original bytes intact.
    corrected = @engine.lifecycle.correct(
      memory_id: record.memory_id, statement: "Canary 5%, then monitor",
      actor: "alice", reason: "correction"
    )
    corrected_again = @engine.lifecycle.correct(
      memory_id: record.memory_id, statement: "Canary 2%, then monitor",
      actor: "alice", reason: "correction"
    )
    assert_equal 3, @engine.repository.current_version(@engine.namespace, "experience", record.memory_id)
    v1 = @engine.repository.version(@engine.namespace, "experience", record.memory_id, 1)
    assert_equal record.statement, v1.fetch(:entry).value.statement
    assert_equal "Canary 5%, then monitor", corrected.statement
    assert_equal "Canary 2%, then monitor", corrected_again.statement
  end

  # T0.2 + T5.3: a self-certified episode never admits as :observed. The
  # admission path must not infer independent observation from a flag; the
  # independently_observed boolean has NO power at all — only the
  # authenticated reconciled-outcome reference admits an episode as :observed,
  # and a CLAIMED reference that does not verify is refused, never silently
  # downgraded to :reported.
  def test_episodes_without_independent_observation_admit_only_as_reported
    unmarked = @engine.admission.admit_episode(
      episode: episode(statement: "Self-certified observation").merge(
        observed_outcome: {"outcome" => "the model saw it", "confidence" => 0.8}
      ),
      owner: "alice"
    )
    assert unmarked.accepted?
    assert_equal :reported, unmarked.record.epistemic_kind

    self_certified = @engine.admission.admit_episode(
      episode: episode(statement: "Self-claimed observation").merge(
        observed_outcome: {"outcome" => "claimed", "independently_observed" => false, "confidence" => 0.8}
      ),
      owner: "alice"
    )
    assert self_certified.accepted?
    assert_equal :reported, self_certified.record.epistemic_kind

    # A truthy string must not upgrade a self-certified episode (strict
    # boolean, not Ruby truthiness).
    stringy = @engine.admission.admit_episode(
      episode: episode(statement: "String-flagged observation").merge(
        observed_outcome: {"outcome" => "claimed", "independently_observed" => "true", "confidence" => 0.8}
      ),
      owner: "alice"
    )
    assert stringy.accepted?
    assert_equal :reported, stringy.record.epistemic_kind

    # T5.3 regression pin: a bare truthy boolean is a self-certified claim —
    # the flag no longer grants :observed.
    flagged = @engine.admission.admit_episode(
      episode: episode(statement: "Boolean-flagged observation").merge(
        observed_outcome: {"outcome" => "claimed", "independently_observed" => true, "confidence" => 0.9}
      ),
      owner: "alice"
    )
    assert flagged.accepted?
    assert_equal :reported, flagged.record.epistemic_kind

    # Only the authenticated reconciled-outcome reference admits :observed.
    independent = @engine.admission.admit_episode(
      episode: episode(statement: "Independently observed"),
      owner: "alice",
      reconciled_outcome: reconciled_outcome,
      verify_source_authority:
    )
    assert independent.accepted?
    assert_equal :observed, independent.record.epistemic_kind
  end

  # T0.3: situation scopes are complete by VALUE, canonicalized to string keys.
  # A nil entity identity is the same as a missing key and is refused; symbol
  # keys are normalized so the episode lands in the situation dimension.
  def test_situation_scopes_are_value_complete_and_key_canonicalized
    partial = episode(statement: "Partial situation scope").merge(
      scopes: scopes(user: "alice").merge(
        "situation_type" => "equipment", "entity_type" => nil, "entity_id" => "c-01"
      )
    )
    assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      @engine.admission.admit_episode(episode: partial, owner: "alice")
    end

    symbolized = episode(statement: "Symbol-keyed situation scope").merge(
      scopes: scopes(user: "alice").merge(
        situation_type: "equipment", entity_type: "compressor", entity_id: "c-01"
      )
    )
    result = @engine.admission.admit_episode(episode: symbolized, owner: "alice")
    assert result.accepted?
    assert_equal "compressor", result.record.scopes.fetch("entity_type")
  end

  # T0.2 code-review finding: string-keyed episodes must not lose their
  # outcome/confidence to symbol-only fetches, and a :reported record must not
  # claim an "observed outcome" in its durable statement.
  def test_episode_statement_preserves_the_outcome_and_says_reported
    result = @engine.admission.admit_episode(
      episode: episode(statement: nil, user: "alice").merge(
        observed_outcome: {
          "outcome" => "the check passed with 2 retries",
          "confidence" => 0.9
        }
      ),
      owner: "alice"
    )
    assert result.accepted?
    assert_equal :reported, result.record.epistemic_kind
    assert_includes result.record.statement, "reported outcome: the check passed with 2 retries"
    refute_includes result.record.statement, "observed outcome: completed"
    assert_equal 0.9, result.record.confidence
  end

  def test_sessions_without_memory_load_with_memory_epoch_none
    # P11-03 at the record layer: a current session without memory still carries
    # the explicit empty memory sentinel.
    record = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "thread.x",
      task: "Explain note.txt",
      task_digest: "d",
      root: "/tmp/x",
      graph_version: "1",
      behavior_version: "tamoz.agent.session/1",
      tool_catalog_digest: "c",
      created_at_ms: 1
    )
    loaded = Tamoz::Agent::SessionRecords.load!(record)
    assert_equal Memory::LEGACY_MEMORY_EPOCH, loaded.fetch("memory_epoch")
    assert_equal 2, loaded.fetch("record_version")

    modern = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "thread.y",
      task: "t",
      task_digest: "d",
      root: "/tmp/y",
      graph_version: "1",
      behavior_version: "tamoz.agent.session/1",
      tool_catalog_digest: "c",
      created_at_ms: 1,
      memory_epoch: {"layers" => %w[experience knowledge wisdom], "retrieval_policy" => "session"}
    )
    assert_equal %w[experience knowledge wisdom], modern.fetch("memory_epoch").fetch("layers")
  end

  def test_lifecycle_transitions_and_eligible_state_set_are_exact
    # P11-04: every transition records actor/authority/reason/prior-version;
    # the eligible reader returns only active/consolidated; expiry transitions
    # by :system; a duplicate rejected candidate does not re-enter.
    result = admit_episode
    record = result.record

    quarantined = @engine.lifecycle.quarantine(memory_id: record.memory_id, actor: "alice", reason: "contradiction")
    assert_equal :quarantined, quarantined.state
    assert_equal "alice", quarantined.transition.fetch("actor")

    superseded = @engine.lifecycle.supersede(memory_id: record.memory_id, actor: "alice", reason: "replaced", replacement_id: "mem.new")
    assert_equal :superseded, superseded.state
    assert_equal "mem.new", superseded.supersession_key

    # Expired record deletes with actor :system.
    @engine.lifecycle.quarantine(memory_id: record.memory_id, actor: "system", reason: "x")
    expired_admission = @engine.admission.admit_episode(
      owner: "alice",
      episode: episode(statement: "Expiring note", valid_until: @clock.to_i - 100)
    )
    @engine.lifecycle.delete(memory_id: expired_admission.record.memory_id, reason: "expiry")
    current = @engine.lifecycle.send(:current_record, expired_admission.record.memory_id, allow_deleted: true)
    assert_equal "system", current.record.transition.fetch("actor")

    # Eligible states: only active/consolidated are retrievable.
    eligible = @engine.retrieval.recall(caller:, query: {terms: ["deploy"]})
    assert_empty eligible.records

    # Duplicate rejected candidate is durable and does not re-enter.
    dup = @engine.admission.admit_episode(episode: episode(statement: "Dupe statement"), owner: "alice")
    dup2 = @engine.admission.admit_episode(episode: episode(statement: "Dupe statement"), owner: "alice")
    assert dup.accepted?
    assert dup2.rejected?
    assert_equal "duplicate_identity", dup2.reason
  end

  def test_admission_reject_matrix_is_durable_and_never_raises
    # P11-12: every forbidden candidate class is a durable :rejected record.
    oversized = episode(statement: "x" * 5_000)
    result = @engine.admission.admit_episode(episode: oversized, owner: "alice")
    assert result.rejected?
    assert_equal "unbounded_statement", result.reason
    assert_equal :rejected, result.record.state

    secret = episode(statement: "the token is sk-ant-abcdef1234567890")
    result = @engine.admission.admit_episode(episode: secret, owner: "alice")
    assert result.rejected?
    assert_equal "secret_shaped", result.reason

    speculation = episode(statement: "The build probably failed because the cache was stale?")
    result = @engine.admission.admit_episode(
      episode: speculation, owner: "alice",
      reconciled_outcome: reconciled_outcome,
      verify_source_authority:
    )
    assert result.rejected?
    assert_equal "speculation_as_fact", result.reason

    # A rejected admission is a durable record with a rejection reason.
    stored = @engine.repository.version(@engine.namespace, "experience", result.record.memory_id, 1)
    assert stored
    assert_equal :rejected, stored.fetch(:entry).value.state
    assert_equal "speculation_as_fact", stored.fetch(:entry).value.rejection_reason
  end

  def test_rejected_storage_failure_is_reported_through_stored_flag
    # The rejection verdict still stands and never raises, but a durable-write
    # failure on the audit record is surfaced (stored? == false), not swallowed.
    # Closing the adapter makes the durable append fail for real.
    @adapter.close
    result = @engine.admission.admit_episode(episode: episode(statement: "x" * 5_000), owner: "alice")
    assert result.rejected?
    refute result.stored?
  end

  def test_no_model_call_decides_admission
    # P11-13: all three gate paths admit with no provider loaded (no model
    # constant is even consulted on the admission path).
    probe = Class.new do
      def generate(*)
        raise "admission must never call a model"
      end
    end.new

    episode_result = @engine.admission.admit_episode(episode: episode(statement: "Gate a"), owner: "alice")
    assert episode_result.accepted?

    owner_result = @engine.admission.admit_owner_request(
      statement: "Prefer the canary strategy for rollouts",
      owner: "alice", authority: "owner", scopes: scopes
    )
    assert owner_result.accepted?
    assert_equal :reported, owner_result.record.epistemic_kind

    # Unknown-gate candidate is default-rejected.
    stray = Memory::MemoryRecord.new(
      memory_id: "mem.stray", layer: :knowledge, klass: :procedure,
      epistemic_kind: :inferred, owner: "alice", scopes: scopes,
      sensitivity: :internal, statement: "A stray claim",
      source_refs: [{"identity" => "src", "digest" => "d", "observed_at" => 1}]
    )
    stray_result = @engine.admission.admit_consolidation_candidate(record: stray, gates: [])
    assert stray_result.rejected?
    assert_equal "consolidation gates missing", stray_result.reason.split(": ").first
    probe # referenced so the model is never invoked
  end

  def test_owner_fast_path_three_negatives
    # P11-15: the owner fast path admits :reported/:prescribed only.
    ok = @engine.admission.admit_owner_request(
      statement: "Prefer two green checks before canary promotion",
      owner: "alice", authority: "owner", scopes: scopes,
      epistemic_kind: :prescribed
    )
    assert ok.accepted?
    assert_equal :prescribed, ok.record.epistemic_kind
    assert_equal :active, ok.record.state

    observed = @engine.admission.admit_owner_request(
      statement: "The build failed", owner: "alice", authority: "owner",
      scopes: scopes, epistemic_kind: :observed
    )
    assert observed.rejected?
    assert_includes observed.reason, "owner_request_cannot_label_observed"

    wisdom = @engine.admission.admit_owner_request(
      statement: "Always use the blue strategy", owner: "alice", authority: "owner",
      scopes: scopes, layer: :wisdom
    )
    assert wisdom.rejected?
    assert_includes wisdom.reason, "owner_request_cannot_create_wisdom"

    secret = @engine.admission.admit_owner_request(
      statement: "The secret key is sk-live-abcdefghijklm", owner: "alice",
      authority: "owner", scopes: scopes
    )
    assert secret.rejected?
    assert_includes secret.reason, "secret_contrary_to_policy"

    grant = @engine.admission.admit_owner_request(
      statement: "The operator approved apply_patch permanently",
      owner: "alice", authority: "owner", scopes: scopes, klass: :constraint
    )
    assert grant.rejected?
    assert_includes grant.reason, "owner_request_cannot_grant_capability"
  end

  def test_owner_fast_path_refusal_lists_negatives_in_policy_order
    # The refusal reason prefixes "owner_fast_path:" and joins the negatives
    # in policy order; reordering or renaming the negative set breaks this.
    result = @engine.admission.admit_owner_request(
      statement: "Always use the blue strategy", owner: "alice",
      authority: "delegate", scopes: scopes, layer: :wisdom
    )
    assert result.rejected?
    assert_nil result.record
    assert_equal(
      "owner_fast_path: owner_request_cannot_create_wisdom, authority_must_be_owner",
      result.reason
    )
  end

  def test_duplicate_identity_refusal_returns_rejection_without_touching_the_durable_row
    # Rerun-idempotency: the second admission of the same identity returns a
    # rejected result carrying duplicate_identity, but the durable row keeps
    # the first admission's accepted version — a duplicate is refused, not
    # persisted as a second rejected record.
    first = admit_episode(statement: "Dupe statement")
    assert first.accepted?

    second = @engine.admission.admit_episode(
      episode: episode(statement: "Dupe statement"), owner: "alice"
    )
    assert second.rejected?
    assert_equal "duplicate_identity", second.reason
    assert_equal :rejected, second.record.state
    assert_equal "duplicate_identity", second.record.rejection_reason
    assert_equal "episode admission", second.record.transition.fetch("reason")

    assert_equal 1, @engine.repository.current_version(
      @engine.namespace, "experience", first.record.memory_id
    )
    stored = @engine.repository.version(
      @engine.namespace, "experience", first.record.memory_id, 1
    )
    assert stored
    assert_equal :active, stored.fetch(:entry).value.state
  end

  def test_recall_marks_trace_and_never_absorbs_itself
    # P11-11/P11-A2: recalled memory is marked in the trace and excluded as
    # new Experience evidence — the self-ingestion loop is closed at the
    # admission boundary.
    admit_episode(statement: "Rollback on two consecutive failed checks")
    trace = []
    recalled = @engine.retrieval.recall(
      caller:, query: {terms: ["rollback"]}, trace:
    )
    assert_equal 1, recalled.records.length
    assert recalled.records.first.transition.fetch("recalled") == true
    recall_events = trace.select { |event| event.type == Memory::Retrieval::RECALL_EVENT }
    assert_equal 1, recall_events.length
    assert_equal recalled.records.first.memory_id, recall_events.first.data.fetch("memory_id")

    # Feeding paraphrased recalled content back as a new episode is rejected:
    # a different statement (different identity) still cannot enter as new
    # Experience evidence — the loop is closed at the admission boundary.
    echo = episode(statement: "We should roll back whenever two checks fail consecutively")
    echo[:recalled_memory] = recalled.records.first.memory_id
    result = @engine.admission.admit_episode(episode: echo, owner: "alice")
    assert result.rejected?
    assert_equal "recalled_as_new", result.reason
  end

  def test_retrieval_budget_truncates_by_rank_and_automatic_drops_lowest
    # P11-10: explicit truncates by rank (never silent); automatic drops the
    # lowest-ranked admissible record and records the drop.
    (1..6).each do |index|
      @engine.admission.admit_owner_request(
        statement: "Rollout rule number #{index}: " + ("canary " * 200),
        owner: "alice", authority: "owner", scopes: scopes,
        epistemic_kind: :reported
      )
    end

    explicit = @engine.retrieval.recall(caller:, query: {terms: ["rollout"]})
    # ~1200-byte statements are ~300 tokens each; 6 of them exceed the 1024
    # token budget, so explicit retrieval truncates by rank.
    assert_operator explicit.records.length, :<, 6
    assert_operator explicit.records.length, :>=, 1
    assert explicit.truncated

    automatic_trace = []
    automatic = @engine.retrieval.recall(
      caller:, query: {terms: ["rollout"]}, trace: automatic_trace, automatic: true
    )
    assert_operator automatic.records.length, :<=, Memory::MemoryLimits.fetch(:max_injected_knowledge)
    drops = automatic_trace.select { |event| event.type == :memory_dropped }
    # Not over the token budget with 6 small records, so no drop events.
    assert_equal automatic.dropped_ids, drops.map { |event| event.data.fetch("memory_id") }
  end

  def test_correction_removes_bad_record_from_active_recall_and_index
    # P11-16: after correction the bad version leaves active recall immediately
    # and the index no longer matches it; a historical read still works.
    result = admit_episode(statement: "Deploy to production directly")
    @engine.lifecycle.correct(
      memory_id: result.record.memory_id,
      statement: "Deploy to staging first",
      actor: "alice", reason: "correction"
    )
    after = @engine.retrieval.recall(caller:, query: {terms: ["directly"]})
    assert_empty after.records
    hit = @engine.retrieval.recall(caller:, query: {terms: ["staging"]})
    assert_equal 1, hit.records.length
    v1 = @engine.repository.version(@engine.namespace, "experience", result.record.memory_id, 1)
    assert_equal "Deploy to production directly", v1.fetch(:entry).value.statement
  end

  def test_deletion_emits_receipt_and_propagates_to_index
    # P11-17: tombstone-delete covers the primary record and index and emits an
    # invariant-54-shape receipt; nothing zombies back into active recall.
    result = admit_episode(statement: "Delete-me policy note")
    receipt = @engine.lifecycle.delete(memory_id: result.record.memory_id, actor: "alice", reason: "test")
    assert_equal 1, receipt.fetch("removed").fetch("primary_record")
    assert_operator receipt.fetch("removed").fetch("index_rows"), :>=, 1
    assert_equal result.record.memory_id, receipt.fetch("memory_id")

    gone = @engine.retrieval.recall(caller:, query: {terms: ["delete"]})
    assert_empty gone.records
  end

  def test_consolidation_preserves_preimage_and_failure_keeps_prior_knowledge
    # P11-14: preimage stored before the rewrite; a rewrite dropping a
    # protected entry is rejected, prior Knowledge stays intact, and a
    # rejected candidate is recorded.
    protected_source = @engine.admission.admit_owner_request(
      statement: "Protected constraint: never auto-promote canaries",
      owner: "alice", authority: "owner", scopes: scopes,
      epistemic_kind: :prescribed, klass: :constraint
    )
    second = @engine.admission.admit_owner_request(
      statement: "Canaries promote after two green checks",
      owner: "alice", authority: "owner", scopes: scopes,
      epistemic_kind: :reported
    )
    candidate = Memory::MemoryRecord.new(
      memory_id: "mem.consolidation-candidate",
      layer: :knowledge, klass: :procedure, state: :candidate,
      epistemic_kind: :inferred, owner: "alice", scopes: scopes,
      sensitivity: :internal,
      statement: "Canary promotion procedure",
      source_refs: [
        {
          "identity" => "episode:e1",
          "digest" => protected_source.record.digest,
          "observed_at" => 1,
          "protected" => true,
          "statement_preview" => "never auto-promote canaries"
        },
        {"identity" => "episode:e2", "digest" => second.record.digest, "observed_at" => 1}
      ],
      confidence: 0.9, confidence_method: "consolidation"
    )

    drop_model = Class.new do
      def generate(stage:, system:, prompt:)
        {"statement" => "Compact canary promotion", "epistemic_kind" => "reported",
         "confidence" => 0.8, "contradictions" => [], "preserved_source_refs" => []}
      end
    end.new
    error = assert_raises(Memory::MemoryConsolidationError) do
      with_consolidation_context do |context|
        @engine.consolidation.consolidate(
          candidates: [candidate], model: drop_model, owner: "alice", scopes:, context:
        )
      end
    end
    assert_includes error.message, "protected entry"

    # The preimage is readable post-failure; the protected policy survives.
    preimage = @engine.store.get("#{@engine.namespace}.consolidation", "candidate.#{candidate.digest[0, 40]}")
    assert preimage
    assert_equal candidate.digest, preimage.value.fetch("preimage_digest")
    still = @engine.retrieval.recall(caller:, query: {terms: ["never"]})
    assert_equal 1, still.records.length
  end

  def test_consolidation_model_raises_typed_error_and_prior_knowledge_intact
    failing = Class.new do
      def generate(stage:, system:, prompt:)
        raise "provider outage"
      end
    end.new
    candidate = Memory::MemoryRecord.new(
      memory_id: "mem.consolidation-b", layer: :knowledge, klass: :procedure,
      state: :candidate, epistemic_kind: :inferred, owner: "alice",
      scopes: scopes, sensitivity: :internal, statement: "Another procedure",
      source_refs: [
        {"identity" => "episode:e1", "digest" => "d1", "observed_at" => 1},
        {"identity" => "episode:e2", "digest" => "d2", "observed_at" => 1}
      ],
      confidence: 0.9, confidence_method: "consolidation"
    )
    assert_raises(Memory::MemoryConsolidationError) do
      with_consolidation_context do |context|
        @engine.consolidation.consolidate(
          candidates: [candidate], model: failing, owner: "alice", scopes:, context:
        )
      end
    end
  end

  # P11 critic defect 1: the consolidation SUCCESS path was dead — store_preimage
  # and mark_consumed both wrote the same key with if_version: nil, so the second
  # write always raised StoreConflictError and no Knowledge record could ever be
  # produced. Now the consume mark is version-keyed.
  def test_consolidation_success_path_admits_knowledge_and_consumes_once
    candidate = Memory::MemoryRecord.new(
      memory_id: "mem.consolidation-success",
      layer: :knowledge, klass: :procedure, state: :candidate,
      epistemic_kind: :inferred, owner: "alice", scopes: scopes,
      sensitivity: :internal,
      statement: "Rollback procedure",
      source_refs: [
        {"identity" => "episode:e1", "digest" => "d1", "observed_at" => 1},
        {"identity" => "episode:e2", "digest" => "d2", "observed_at" => 1}
      ],
      confidence: 0.9, confidence_method: "consolidation"
    )
    model = Class.new do
      def generate(stage:, system:, prompt:)
        {"statement" => "Compact rollback procedure", "epistemic_kind" => "reported",
         "confidence" => 0.8, "contradictions" => [],
         "preserved_source_refs" => ["d1", "d2"]}
      end
    end.new

    result = with_consolidation_context do |context|
      @engine.consolidation.consolidate(
        candidates: [candidate], model:, owner: "alice", scopes:, context:
      )
    end
    assert result

    # The Knowledge record is active and recallable — the success path produces
    # a real record.
    recalled = @engine.retrieval.recall(caller:, query: {terms: ["rollback"]})
    assert recalled.records.any? { |record| record.layer == :knowledge && record.state == :active }

    # Rerun-idempotency: the candidate was consumed exactly once.
    error = assert_raises(Memory::MemoryConsolidationError) do
      with_consolidation_context do |context|
        @engine.consolidation.consolidate(candidates: [candidate], model:, owner: "alice", scopes:, context:)
      end
    end
    assert_includes error.message, "already consumed"
  end

  # P-01: the non-deterministic consolidation provider call is routed through
  # EffectDispatcher under a deterministic logical key, so it is issued exactly
  # once and a crash-time re-drive replays the recorded receipt rather than
  # generating a fresh, different result (the replay itself is a dispatcher
  # property, proven at that boundary). A durable effect context is required.
  def test_consolidation_model_call_is_issued_once_through_the_durable_boundary
    candidate = Memory::MemoryRecord.new(
      memory_id: "mem.consolidation-replay",
      layer: :knowledge, klass: :procedure, state: :candidate,
      epistemic_kind: :inferred, owner: "alice", scopes: scopes,
      sensitivity: :internal, statement: "Replay-safe procedure",
      source_refs: [
        {"identity" => "episode:e1", "digest" => "d1", "observed_at" => 1},
        {"identity" => "episode:e2", "digest" => "d2", "observed_at" => 1}
      ],
      confidence: 0.9, confidence_method: "consolidation"
    )
    generations = 0
    model = Object.new
    model.define_singleton_method(:generate) do |stage:, system:, prompt:|
      generations += 1
      {"statement" => "Replay-safe procedure synthesized", "epistemic_kind" => "reported",
       "confidence" => 0.8, "contradictions" => [], "preserved_source_refs" => ["d1", "d2"]}
    end

    result = with_consolidation_context do |context|
      @engine.consolidation.consolidate(
        candidates: [candidate], model:, owner: "alice", scopes:, context:
      )
    end

    refute result.rejected?
    assert_equal 1, generations, "the durable boundary issues exactly one provider call"
  end

  def test_consolidation_requires_a_durable_effect_context
    candidate = Memory::MemoryRecord.new(
      memory_id: "mem.needs-context", layer: :knowledge, klass: :procedure,
      state: :candidate, epistemic_kind: :inferred, owner: "alice", scopes: scopes,
      sensitivity: :internal, statement: "Needs a context",
      source_refs: [
        {"identity" => "episode:e1", "digest" => "d1", "observed_at" => 1},
        {"identity" => "episode:e2", "digest" => "d2", "observed_at" => 1}
      ],
      confidence: 0.9, confidence_method: "consolidation"
    )
    model = Object.new
    model.define_singleton_method(:generate) { |**| flunk "the model must not be called without a durable context" }

    error = assert_raises(Memory::MemoryConsolidationError) do
      @engine.consolidation.consolidate(
        candidates: [candidate], model:, owner: "alice", scopes:, context: Object.new
      )
    end
    assert_includes error.message, "durable effect context"
  end

  # P11 critic defect 2: Lifecycle#delete never tombstoned the STORE head
  # (append hardcoded deleted: false), so purge_expired / Lifecycle#purge could
  # never physically remove an agent-deleted record — ciphertext persisted
  # forever (invariant 31). Now the :deleted append carries the tombstone flag.
  def test_delete_tombstones_the_store_then_purge_removes_ciphertext_after_retention
    admitted = @engine.admission.admit_owner_request(
      statement: "Purge me after deletion", owner: "alice", authority: "owner",
      scopes:, epistemic_kind: :reported, klass: :fact
    )
    memory_id = admitted.record.memory_id

    receipt = @engine.lifecycle.delete(memory_id:, actor: "alice")
    assert receipt.is_a?(Hash)
    assert receipt.key?("removed") && receipt.key?("retained") && receipt.key?("pending")

    # Recall excludes the deleted record immediately.
    recalled = @engine.retrieval.recall(caller:, query: {terms: ["purge"]})
    refute recalled.records.any? { |record| record.memory_id == memory_id }

    # Before the retention boundary the purge refuses (no receipt emitted).
    assert_raises(Tamoz::StoreError) do
      @engine.lifecycle.purge(memory_id:, layer: admitted.record.layer.to_s)
    end

    # After the boundary the purge physically removes ciphertext + index rows.
    retention_s = @engine.store.adapter.limits.deletion_retention
    future = Time.at(Time.now.to_i + retention_s.to_i + 60)
    purge = @engine.lifecycle.purge(memory_id:, layer: admitted.record.layer.to_s, now: future)
    assert purge.fetch("removed").any?
  end

  def test_behavior_transition_claim_apply_finalize_and_pinning
    # P11-19: Wisdom activates only through a BehaviorTransition at first
    # intake; a second apply is a no-op; existing threads stay pinned.
    snapshot = {"wisdom" => "Prefer two green checks before promotion"}
    transition, reserved = @engine.transitions.record(
      kind: :wisdom_promotion,
      candidate_id: "wis.canary",
      candidate_digest: "sha256:candidate",
      behavior_snapshot: snapshot,
      behavior_version_after: "tamoz.agent.session/2",
      promotion_evidence_digest: "sha256:evidence",
      human_gate_evidence: "human:operator-approval-1",
      created_by: "test"
    )
    assert_equal 1, reserved
    assert_equal :recorded, transition.status

    # Claim (Store CAS before any checkpoint write): exactly one consumer wins.
    claimed = @engine.transitions.claim(
      transition_id: transition.transition_id, owner: "intake", attempt: 1
    )
    assert_equal :claimed, claimed.status
    assert_equal({"owner" => "intake", "attempt" => 1}, claimed.claimant)
    assert_raises(Memory::BehaviorTransitionClaimConflictError) do
      @engine.transitions.claim(
        transition_id: transition.transition_id, owner: "other", attempt: 1
      )
    end

    # Apply: session record carries behavior_version_after + snapshot + epoch
    # reason; then finalize CASes the control record and activates idempotently.
    control = @engine.transitions.finalize(
      transition_id: transition.transition_id, consumed_by: "session.canary"
    )
    assert_equal "tamoz.agent.session/2", control.active_version
    assert_nil control.pending_transition_id
    activated = @engine.transitions.transition(transition.transition_id)
    assert_equal :activated, activated.status
    assert_equal "session.canary", activated.consumed_by

    # Second finalize (same transition id) is refused: not pending anymore.
    assert_raises(Memory::BehaviorTransitionClaimConflictError) do
      @engine.transitions.finalize(
        transition_id: transition.transition_id, consumed_by: "session.b"
      )
    end

    # New intakes read the active snapshot from the control record.
    assert_equal "tamoz.agent.session/2", @engine.transitions.active.fetch("active_version")
    assert_equal snapshot, @engine.transitions.active_snapshot
  end

  def test_behavior_transition_serialized_pending_and_release_rules
    # DR-1 T5/T7: two pipelines from one baseline — one pending; the loser
    # cannot reserve; release is permitted only when nothing references the
    # transition; otherwise recovery finalizes.
    @engine.transitions.record(
      kind: :wisdom_promotion, candidate_id: "wis.a", candidate_digest: "sha256:a",
      behavior_snapshot: {"wisdom" => "a"}, behavior_version_after: "tamoz.agent.session/2",
      promotion_evidence_digest: "sha256:ev", human_gate_evidence: "human:op"
    )
    assert_raises(Memory::BehaviorTransitionClaimConflictError) do
      @engine.transitions.record(
        kind: :wisdom_promotion, candidate_id: "wis.b", candidate_digest: "sha256:b",
        behavior_snapshot: {"wisdom" => "b"}, behavior_version_after: "tamoz.agent.session/3",
        promotion_evidence_digest: "sha256:ev2", human_gate_evidence: "human:op"
      )
    end

    pending = @engine.transitions.pending_transition
    assert pending
    id = pending.transition_id
    # No session references it yet -> release clears pending.
    assert_equal :released, @engine.transitions.release_or_finalize(
      transition_id: id, session_references: ->(_id) { false }
    )
    assert_nil @engine.transitions.pending_transition_id

    # A session that references it -> recovery finalizes.
    @engine.transitions.record(
      kind: :wisdom_promotion, candidate_id: "wis.c", candidate_digest: "sha256:c",
      behavior_snapshot: {"wisdom" => "c"}, behavior_version_after: "tamoz.agent.session/3",
      promotion_evidence_digest: "sha256:ev3", human_gate_evidence: "human:op"
    )
    id2 = @engine.transitions.pending_transition.transition_id
    @engine.transitions.claim(transition_id: id2, owner: "intake", attempt: 1)
    outcome = @engine.transitions.release_or_finalize(
      transition_id: id2, session_references: ->(_id) { true }
    )
    assert_equal "tamoz.agent.session/3", outcome.active_version
    assert_equal :activated, @engine.transitions.transition(id2).status
  end

  def test_wisdom_promotion_gates
    # P11-21: holdout-gated, human-gated, one-candidate bound, recommendation
    # only.
    candidate = Memory::MemoryRecord.new(
      memory_id: "wis.planning", layer: :wisdom, klass: :strategy,
      state: :candidate, epistemic_kind: :inferred, owner: "alice",
      scopes: scopes, sensitivity: :internal,
      statement: "Prefer two green checks before promotion",
      source_refs: [{"identity" => "k1", "digest" => "d", "observed_at" => 1}],
      confidence: 0.95, confidence_method: "evaluation"
    )

    # No human gate for a capability-affecting promotion -> refused.
    assert_raises(Memory::MemoryPolicyError) do
      @engine.wisdom.promote(
        candidate: candidate.with(klass: :policy),
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: nil},
        behavior_snapshot: {"wisdom" => "two green checks"},
        behavior_version_after: "tamoz.agent.session/2"
      )
    end

    # Human gate evidence missing -> UnverifiedTransitionError.
    assert_raises(Memory::UnverifiedTransitionError) do
      @engine.wisdom.promote(
        candidate:,
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: "self-approved"},
        behavior_snapshot: {"wisdom" => "two green checks"},
        behavior_version_after: "tamoz.agent.session/2"
      )
    end

    # Holdout failing -> refused.
    assert_raises(Memory::UnverifiedTransitionError) do
      @engine.wisdom.promote(
        candidate:,
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => false} }},
        human_gate: {required: false, evidence: "human:operator-1"},
        behavior_snapshot: {"wisdom" => "two green checks"},
        behavior_version_after: "tamoz.agent.session/2"
      )
    end

    promoted = @engine.wisdom.promote(
      candidate:,
      development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
      holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
      human_gate: {required: false, evidence: "human:operator-1"},
      behavior_snapshot: {"wisdom" => "two green checks"},
      behavior_version_after: "tamoz.agent.session/2"
    )
    assert_equal true, promoted.fetch("recommendation_only")
    assert_equal :recorded, promoted.fetch("transition").status

    # One-candidate bound: a second promotion while one is pending is refused.
    assert_raises(Memory::MemoryPolicyError) do
      @engine.wisdom.promote(
        candidate: candidate.with(memory_id: "wis.other"),
        development_evaluation: {evidence_digest: "sha256:dev", passed: true, outcomes_digest: "sha256:o"},
        holdout: {path: "/outside", verifier: ->(_path, _digest) { {"passed" => true} }},
        human_gate: {required: false, evidence: "human:operator-1"},
        behavior_snapshot: {"wisdom" => "other"},
        behavior_version_after: "tamoz.agent.session/3"
      )
    end
  end

  def test_content_addressed_snapshot_rewrite_is_idempotent
    # P12-I regression for the DR-1 rollback fix (slice I, 2026-08-02): the
    # snapshot namespace is content-addressed — the key IS the digest of the
    # value. Writing it with `if_version: nil` raised StoreConflictError
    # whenever the same snapshot content was recorded twice, which is exactly
    # what DR-1 §7 rollback does (it re-records the PRIOR snapshot's bytes to
    # restore them byte-identically) and what two promotions with identical
    # snapshot content would do. "Already present with identical bytes" must be
    # success for a content-addressed key.
    snapshot = {"wisdom" => "rollback target bytes"}
    first, = @engine.transitions.record(
      kind: :wisdom_promotion,
      candidate_id: "wis.rollback-1",
      candidate_digest: "sha256:candidate-1",
      behavior_snapshot: snapshot,
      behavior_version_after: "tamoz.agent.session/2",
      promotion_evidence_digest: "sha256:evidence-1",
      human_gate_evidence: "human:operator-1",
      created_by: "test"
    )
    claimed = @engine.transitions.claim(
      transition_id: first.transition_id, owner: "intake", attempt: 1
    )
    assert_equal :claimed, claimed.status
    @engine.transitions.finalize(
      transition_id: first.transition_id, consumed_by: "session.canary"
    )
    assert_equal :activated, @engine.transitions.transition(first.transition_id).status
    assert_equal "tamoz.agent.session/2", @engine.transitions.active.fetch("active_version")

    # A second promotion carrying the SAME snapshot bytes (the rollback shape:
    # restore the prior snapshot's exact content) must record cleanly.
    second, = @engine.transitions.record(
      kind: :wisdom_promotion,
      candidate_id: "wis.rollback-2",
      candidate_digest: "sha256:candidate-2",
      behavior_snapshot: snapshot,
      behavior_version_after: "tamoz.agent.session/3",
      promotion_evidence_digest: "sha256:evidence-2",
      human_gate_evidence: "human:operator-1",
      created_by: "test"
    )
    assert_equal :recorded, second.status

    # The stored snapshot still resolves to the SAME bytes under its digest.
    stored = @engine.store.get(
      Memory::BehaviorTransition::SNAPSHOTS_NAMESPACE,
      Memory::BehaviorTransition.snapshot_digest(snapshot)
    )
    assert stored
    assert_equal(
      {"snapshot" => snapshot, "digest" => Memory::BehaviorTransition.snapshot_digest(snapshot)},
      Tamoz::Core.canonical(stored.value)
    )
  end
end
