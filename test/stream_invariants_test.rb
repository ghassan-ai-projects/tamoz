# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "tamoz/stream/approval_relay"
require "tamoz/stream/reconsideration"
require "json"

# T8.2 (PLAN_TAMOZ_STREAM_BUILD §7): the nine release-blocking stream
# invariants as executable tests. The audit found the current evals cover the
# agent, not the worker contract; this suite pins the worker contract. Each
# clause exercises the REAL code path, not a stub.
class StreamInvariantsTest < Minitest::Test
  Reconsideration = Tamoz::Stream::Reconsideration

  # Invariant 1: the supervised episode path computes no watermark, event
  # time, lateness, or window membership — the deterministic plane belongs to
  # the stream (§2, §6.2). T8.3 retired the old P14 engine (which carried
  # those concepts) by forward migration; the scan covers the surviving
  # worker files.
  def test_invariant_1_the_episode_path_computes_no_stream_plane_concepts
    episode_files = ROOT.glob(
      "gems/tamoz-stream/lib/tamoz/stream/{episode_*,evidence_*,situation_*,capability_host,reconsideration,approval_relay,outcome_subscriber,verification_store,situation_memory,artifact_store,decision_builder}*.rb"
    )
    refute_empty episode_files
    %w[watermark event_time lateness window partition_key].each do |token|
      episode_files.each do |path|
        refute_includes File.read(path), token,
                        "#{path} must not compute the stream's deterministic plane (#{token})"
      end
    end
  end

  # Invariant 2: a snapshot digest mismatch terminates the episode BEFORE any
  # model call (PROTOCOL §8: fail loudly; never prefer a locally recomputed
  # value).
  def test_invariant_2_snapshot_mismatch_terminates_before_any_model_call
    directory = Dir.mktmpdir("tamoz-invariant2")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    app = simple_graph("invariant-2").compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )
    snapshot = basic_snapshot
    wire = basic_request("ep-i2", snapshot).tap do |request|
      request.snapshot_json = request.snapshot_json.sub("sit-1", "sit-9")
    end

    events = runner.run(wire).each.to_a
    assert_equal :TERMINAL_STATUS_FAILED, events.last.terminal.status
    assert_empty events.select { |event| event.model_started != nil },
                 "no model call may run for a tampered snapshot"
    diagnostic = events.find { |event| event.diagnostic != nil }
    refute_nil diagnostic, "the mismatch must fail loudly with a diagnostic"
    assert_equal "stream_snapshot_digest_mismatch", diagnostic.diagnostic.code,
                 "the mismatch must fail loudly with its typed diagnostic"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # Invariant 3: an interrupt inside a stream episode is terminal, never a
  # wait (PROTOCOL §3.4; T0.4).
  def test_invariant_3_an_interrupt_in_a_stream_episode_is_terminal
    directory = Dir.mktmpdir("tamoz-invariant3")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    graph = Tamoz.graph(name: "invariant-3", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :answer, default: nil
      node(:ask, implementation_name: "episode.ask", version: "1") do |_state, context|
        {answer: Tamoz.interrupt({"question" => "approve"}, context)}
      end
      edge Tamoz::START, :ask
      edge :ask, Tamoz::END
    end
    app = graph.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )

    events = runner.run(basic_request("ep-i3", basic_snapshot)).each.to_a
    terminal = events.last.terminal
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status,
                 "a non-interactive episode interrupt is a typed terminal failure"
    diagnostic = events.find { |event| event.diagnostic != nil }
    refute_nil diagnostic, "the interrupt must surface a diagnostic"
    assert_equal "interrupt_in_non_interactive_episode", diagnostic.diagnostic.code,
                 "the interrupt's typed category must cross the wire, not a bare internal_error"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # Invariant 4: an Experience is admitted only from a Tamoz-executed episode
  # with a reconciled outcome and full provenance — no self-certification, no
  # learning from another executor's episode, an unreconciled verdict, or a
  # forged source authority (T5.3).
  def test_invariant_4_experience_requires_a_reconciled_outcome_with_provenance
    directory = Dir.mktmpdir("tamoz-invariant4")
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "memory.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    engine = Tamoz::Agent::Memory::Engine.new(
      tenant: "acme", adapter:, protection: nil, clock: -> { Time.at(1_700_000_000) }
    )
    episode = {
      session_id: "s1", episode_id: "s1", attempt_id: "at-1",
      statement: "learned fact", task: "t", plan_digest: "sha256:#{"p" * 64}",
      completed_at: 1, scopes: {"tenant" => "acme", "user" => "stream", "project" => "stream"},
      sensitivity: :internal, decisions: [], corrections: [],
      observed_outcome: {"outcome" => "confirmed", "confidence" => 0.9}
    }

    # No reference: self-certified, admitted only as :reported.
    self_certified = engine.admission.admit_episode(episode:, owner: "stream")
    assert self_certified.accepted?
    assert_equal :reported, self_certified.record.epistemic_kind

    # A forged source authority is refused.
    forged = {
      "outcome_id" => "o", "outcome_digest" => "sha256:#{"c" * 64}",
      "command_id" => "c", "decision_id" => "d-1", "source_authority" => "attacker",
      "reconciliation_version" => 1, "observation_status" => "verified",
      "episode_id" => "s1", "attempt_id" => "at-1"
    }
    forged_error = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: forged,
        verify_source_authority: ->(reference) { reference.fetch("source_authority") == "stream-1" }
      )
    end
    assert_includes forged_error.message, "forged_source_authority"

    # An unreconciled verdict is never learned from.
    unlearnable = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: forged.merge("observation_status" => "inconclusive"),
        verify_source_authority: ->(_reference) { true }
      )
    end
    assert_includes unlearnable.message, "unlearnable_verdict"

    # A reference for ANOTHER executor's episode is foreign.
    foreign = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: forged.merge("episode_id" => "s9"),
        verify_source_authority: ->(_reference) { true }
      )
    end
    assert_includes foreign.message, "foreign_episode"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # Invariant 5: a relayed approval never bypasses the stream's revalidation.
  # The relay's ONLY effect on the stream is the assertion-bound submission —
  # it has no auto-approve path and the answer is always an input to policy.
  def test_invariant_5_a_relayed_approval_is_assertion_bound_submission_only
    submissions = []
    submission = Class.new do
      define_method(:submit) { |**args| submissions << args; args.fetch(:approval_id) }
    end.new
    signer = Class.new do
      def key_id = "key-1"
      def sign(bytes) = "sig-#{bytes.bytesize}"
    end.new
    delivery = Class.new do
      def deliver(**args) = "receipt"
      def edit_in_place(**_args) = nil
    end.new
    store = Class.new do
      def claim(_nonce) = true
    end.new
    relay = Tamoz::Stream::ApprovalRelay.new(
      delivery:, submission:, nonce_store: store, signer:, relay_id: "relay-1"
    )

    relay.submit_decision(
      approval: {
        "approval_id" => "apr-1", "tenant_id" => "acme",
        "intent_digest" => "sha256:#{"a" * 64}",
        "snapshot_digest" => "sha256:#{"b" * 64}",
        "expires_at" => "2026-08-19T00:00:00Z", "audience" => "stream-1"
      },
      approver_id: "technician-7", decision: "approve"
    )

    assert_equal 1, submissions.length
    assertion = submissions.fetch(0).fetch(:assertion)
    assert_equal "approve", assertion.fetch("decision")
    assert_equal "relay-1", assertion.fetch("relay_id")
    refute_equal assertion.fetch("relay_id"), assertion.fetch("approver_id")
    # The signed assertion binds the grounding digests — the stream revalidates
    # against them; the relay cannot present an approval without them.
    assert_equal "sha256:#{"a" * 64}", assertion.fetch("intent_digest")
  end

  # Invariant 6: a withdrawn approval updates the delivered message — the
  # channel contract's edit-in-place, so the technician does not act on a
  # stale condition.
  def test_invariant_6_a_withdrawn_approval_edits_the_delivered_message
    edits = []
    delivery = Class.new do
      define_method(:deliver) { |**args| "receipt-1" }
      define_method(:edit_in_place) { |**args| edits << args }
    end.new
    relay = Tamoz::Stream::ApprovalRelay.new(
      delivery:, submission: Class.new { def submit(**_args) = "ok" }.new,
      nonce_store: Class.new { def claim(_n) = true }.new,
      signer: Class.new { def key_id = "k"; def sign(b) = "s" }.new,
      relay_id: "relay-1"
    )

    relay.withdraw(message_id: "receipt-1")

    assert_equal 1, edits.length
    assert_equal "receipt-1", edits.fetch(0).fetch(:message_id)
    assert_includes edits.fetch(0).fetch(:text), "withdrawn"
  end

  # Invariant 7: a compensating intent carries its own risk class — never
  # inherited from the original intent, never assumed safe because it undoes
  # something.
  def test_invariant_7_a_compensating_intent_carries_its_own_risk_class
    prior = {
      "decision_id" => "d",
      "intents" => [{"type" => "maintenance.ticket", "risk_class" => "R1"}]
    }
    command = {
      "command_id" => "cmd_1", "intent_type" => "transfer.product",
      "status" => "dispatched"
    }
    wire = Agenticstream::Runtime::V1::Reconsideration.new(
      prior_decision_json: Tamoz::Core.jcs(prior),
      executed_command_json: [Tamoz::Core.jcs(command)],
      observed_outcome_json: [],
      correction_json: Tamoz::Core.jcs(
        {"reason" => "prior_action_invalidated", "invalidates" => ["cmd_1"]}
      )
    )
    parsed = Reconsideration.parse(wire)
    judgements = Reconsideration.judge(parsed:)
    intents = Reconsideration.build_compensating_intents(
      judgements,
      episode: {
        episode_id: "e", attempt_id: "a", fence: 1,
        tenant_id: "t", situation_id: "s", situation_version: 1,
        risk_ceiling: "r4"
      },
      snapshot: {"situation_id" => "s", "situation_version" => 1}
    )

    assert_equal 1, intents.length
    assert_equal "R3", intents.fetch(0).fetch("risk_class"),
                 "a transfer compensation is R3, not the original intent's class"
    refute_equal "R1", intents.fetch(0).fetch("risk_class")
  end

  # Invariant 8: a watch condition is scoped to one situation, expiring, and
  # count-bounded (PROTOCOL §4.1).
  def test_invariant_8_a_watch_condition_is_scoped_expiring_and_bounded
    envelope = Tamoz::Stream::EpisodeRequestEnvelope.new(
      Agenticstream::Runtime::V1::EpisodeRequest.new(
        protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
        fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
        kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
        risk_ceiling: :RISK_CLASS_R0
      ),
      nil
    )
    snapshot = {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.2}
    }
    decision, = Tamoz::Stream::DecisionBuilder.build(
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "x", confidence: 0.3,
                watch_metric: "condition_score", watch_threshold: 0.8},
      now: Time.utc(2026, 8, 12)
    )
    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type")
    assert_equal "sit-1", intent.fetch("situation_id"),
                 "a watch condition is scoped to exactly one situation"
    assert intent.fetch("parameters").fetch("expression").start_with?("situation."),
           "the expression is situation-scoped, never a tenant or spec"
    assert intent.key?("expires_at"), "a watch condition is expiring"
    assert_operator decision.fetch("intents").length, :<=, Reconsideration::MAX_INTENTS,
                    "watch conditions are count-bounded"
  end

  # Invariant 9: every vector in the shared contract file reproduces exactly
  # (the executable spec for RFC 8785 + the domain digest).
  def test_invariant_9_every_shared_contract_vector_reproduces_exactly
    vectors = JSON.parse(
      File.read(
        ROOT.join("gems/tamoz-stream/contracts/canonicalization-vectors.json"),
        encoding: Encoding::UTF_8
      )
    )
    vectors.fetch("accept").each do |vector|
      document = vector.fetch("input")
      assert_equal(
        vector.fetch("canonical"),
        Tamoz::Core.jcs_json(JSON.generate(document)),
        "accept vector #{vector.fetch("name")} must reproduce exactly"
      )
      assert_equal(
        vector.fetch("digest"),
        Tamoz::Core.digest(vector.fetch("domain"), document),
        "digest vector #{vector.fetch("name")} must reproduce exactly"
      )
    end
  end

  private

  def simple_graph(name)
    Tamoz.graph(name:, version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 2, output_tokens: 1}})
        {primary_hypothesis: "bearing wear", confidence: 0.9}
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
  end

  def basic_snapshot
    {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.9}
    }
  end

  def basic_request(episode_id, snapshot)
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id:, attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      allowed_intent_types: ["create_maintenance_ticket"],
      capability_token: "opaque.hmac.token",
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot)
    )
  end
end
