# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "tamoz/stream/outcome_subscriber"
require "tamoz/stream/verification_store"
require "tamoz/stream/situation_memory"

# T5 (PLAN_TAMOZ_STREAM_BUILD T5): the learning loop. The audit's core gap was
# "the admission guard exists but nothing feeds it". This suite closes the
# loop on the tamoz side:
#   T5.1 outcome_subscriber — Channel B consumer with durable resume, dedup,
#        resnapshot, poison-skip, backpressure (tested against a scripted
#        frame source; the live SSE endpoint is the stream's).
#   T5.2 verification store — awaiting → observed → reconciled; learnable only
#        on a settled verdict (verified/refuted); inconclusive and
#        superseded_before_verification are recorded and never learned from.
#   T5.3 admission — :observed ONLY with an authenticated reconciled-outcome
#        reference; a bare boolean, a forged authority, a foreign episode, or
#        an unlearnable verdict is refused.
#   T5.4 situation_memory — same-tenant-AND-same-entity-type relatedness
#        boundary over the T0.3 scopes.
class StreamLearningLoopTest < Minitest::Test
  Subscriber = Tamoz::Stream::OutcomeSubscriber
  VerificationStore = Tamoz::Stream::VerificationStore
  SituationMemory = Tamoz::Stream::SituationMemory

  Frame = Data.define(:type, :cursor, :event, :data, :control)

  class ScriptedTransport
    attr_reader :opens, :resnapshot_calls

    def initialize(frames: [], resnapshot_cursor: "900")
      @frames = frames
      @opens = []
      @resnapshot_calls = []
      @resnapshot_cursor = resnapshot_cursor
    end

    def open(cursor:, credential:)
      @opens << {cursor:, credential:}
      @frames.each
    end

    def resnapshot(cursor:, credential:)
      @resnapshot_calls << {cursor:, credential:}
      @resnapshot_cursor
    end
  end

  class MemoryCursorStore
    attr_reader :cursor

    def initialize = @cursor = nil

    def read = @cursor

    def write(value) = @cursor = value
  end

  def cloud_event(type, id, data: {}, source: "stream-1")
    JSON.generate({"id" => id, "source" => source, "type" => type, "data" => data})
  end

  def event_frame(cursor, type, id, data: {})
    Frame.new(
      type: :event, cursor:, event: type,
      data: cloud_event(type, id, data:), control: nil
    )
  end

  # --- T5.1: the Channel B subscriber --------------------------------------

  def test_resume_carries_the_stored_cursor_and_credential
    store = MemoryCursorStore.new
    store.write("41")
    transport = ScriptedTransport.new(frames: [
      Frame.new(type: :eof, cursor: nil, event: nil, data: nil, control: nil)
    ])
    subscriber = Subscriber.new(
      cursor_store: store, handlers: {}, credential: "sub-cred-1"
    )

    subscriber.run(transport:)

    assert_equal({cursor: "41", credential: "sub-cred-1"}, transport.opens.fetch(0))
  end

  def test_at_least_once_delivery_deduplicates_on_source_and_id
    store = MemoryCursorStore.new
    calls = []
    handlers = {
      "io.agenticstream.test.v1" => ->(event) { calls << event.id }
    }
    transport = ScriptedTransport.new(frames: [
      event_frame("10", "io.agenticstream.test.v1", "evt-1"),
      event_frame("11", "io.agenticstream.test.v1", "evt-1")
    ])
    Subscriber.new(
      cursor_store: store, handlers:, credential: "c"
    ).run(transport:)

    assert_equal ["evt-1"], calls, "a redelivered event is deduplicated"
    assert_equal "11", store.cursor, "the cursor advances past both frames"
  end

  def test_the_cursor_advances_only_after_successful_dispatch
    store = MemoryCursorStore.new
    handler = ->(event) { raise "boom" if event.id == "evt-1" }
    frames = [
      event_frame("10", "io.agenticstream.test.v1", "evt-1"),
      event_frame("11", "io.agenticstream.test.v1", "evt-2")
    ]
    subscriber = Subscriber.new(
      cursor_store: store, handlers: {"io.agenticstream.test.v1" => handler},
      credential: "c", max_poison_retries: 1
    )

    # First failure: the cursor stays put (redelivery next pass).
    subscriber.run(transport: ScriptedTransport.new(frames:))
    assert_nil store.cursor,
               "a failed dispatch must not advance the cursor (redelivery)"

    # Second failure of the same event exceeds the bound: skipped + recorded,
    # the cursor advances, and the pass continues to the next frame.
    subscriber.run(transport: ScriptedTransport.new(frames:))
    assert_equal 1, subscriber.skipped.length
    assert_equal "evt-1", subscriber.skipped.fetch(0).fetch(:id)
    assert_equal "11", store.cursor,
                 "after the bounded retries the poison event is skipped and the pass continues"
  end

  def test_cursor_expired_forces_an_audited_resnapshot
    store = MemoryCursorStore.new
    store.write("0")
    transport = ScriptedTransport.new(frames: [
      Frame.new(type: :control, cursor: "0", event: nil, data: nil, control: "cursor_expired"),
      event_frame("910", "io.agenticstream.test.v1", "evt-1"),
      Frame.new(type: :eof, cursor: nil, event: nil, data: nil, control: nil)
    ])
    subscriber = Subscriber.new(
      cursor_store: store, handlers: {}, credential: "c"
    )

    subscriber.run(transport:)

    assert_equal({cursor: "0", credential: "c"}, transport.opens.fetch(0),
                 "the pass resumes from the stored cursor")
    assert_equal 1, transport.resnapshot_calls.length
    assert_equal "900", subscriber.resnapshots.fetch(0).fetch(:to),
                 "the resnapshot boundary is audited"
    assert_equal "910", store.cursor,
                 "after the resnapshot the pass continues from the fresh cursor"
  end

  def test_subscriber_too_slow_disconnects_and_resumes_from_the_last_ack
    store = MemoryCursorStore.new
    store.write("20")
    transport = ScriptedTransport.new(frames: [
      Frame.new(type: :control, cursor: "21", event: nil, data: nil, control: "subscriber_too_slow"),
      event_frame("22", "io.agenticstream.test.v1", "evt-after")
    ])
    calls = []
    subscriber = Subscriber.new(
      cursor_store: store,
      handlers: {"io.agenticstream.test.v1" => ->(event) { calls << event.id }},
      credential: "c"
    )

    subscriber.run(transport:)

    assert_empty calls, "the pass ends at the backpressure signal"
    assert_equal "20", store.cursor
  end

  def test_an_unhandled_event_type_is_acknowledged_not_poisoned
    store = MemoryCursorStore.new
    subscriber = Subscriber.new(cursor_store: store, handlers: {}, credential: "c")
    subscriber.run(transport: ScriptedTransport.new(frames: [
      event_frame("10", "io.agenticstream.unsubscribed.v1", "evt-1")
    ]))

    assert_equal "10", store.cursor
    assert_empty subscriber.skipped
  end

  # --- T5.2: the verification store ------------------------------------------

  def test_verification_opens_awaiting_and_closes_learnable_on_a_settled_verdict
    store = VerificationStore.new(clock: -> { Time.at(1_700_000_000) })
    store.open(
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      episode_id: "ep-1", attempt_id: "at-1",
      decision_digest: "sha256:#{"d" * 64}",
      episode: {task: "t"}, decision_id: "decision-7"
    )
    assert_equal :awaiting, store.fetch(intent_id: "intent.ep-1.at-1.1.maintenance.ticket").state

    store.record_outcome(
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      outcome_id: "out-9", outcome_digest: "sha256:#{"o" * 64}",
      command_id: "cmd-7"
    )
    store.reconcile(
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      verdict: "verified", reconciliation_version: "1", source_authority: "stream-1"
    )

    row = store.fetch(intent_id: "intent.ep-1.at-1.1.maintenance.ticket")
    assert_equal :reconciled, row.state
    assert row.learnable?
    reference = store.reference(intent_id: "intent.ep-1.at-1.1.maintenance.ticket")
    assert_equal "out-9", reference.fetch("outcome_id")
    assert_equal "verified", reference.fetch("observation_status")
    assert_equal "cmd-7", reference.fetch("command_id")
    assert_equal "decision-7", reference.fetch("decision_id")
  end

  def test_unlearnable_verdicts_are_recorded_and_never_learned_from
    store = VerificationStore.new(clock: -> { Time.at(1_700_000_000) })
    intent = "intent.ep-1.at-1.1.maintenance.ticket"
    store.open(intent_id: intent, episode_id: "ep-1", attempt_id: "at-1",
               decision_digest: "sha256:#{"d" * 64}", episode: {task: "t"})
    store.record_outcome(intent_id: intent, outcome_id: "out-9",
                         outcome_digest: "sha256:#{"o" * 64}")
    store.reconcile(intent_id: intent, verdict: "inconclusive",
                    reconciliation_version: "1", source_authority: "stream-1")

    row = store.fetch(intent_id: intent)
    assert_equal :reconciled, row.state
    refute row.learnable?
    assert_nil store.reference(intent_id: intent),
               "an inconclusive verdict must never feed admission"
  end

  def test_duplicate_verification_open_is_refused
    store = VerificationStore.new
    store.open(intent_id: "i1", episode_id: "e", attempt_id: "a",
               decision_digest: "d", episode: {})
    assert_raises(VerificationStore::VerificationError) do
      store.open(intent_id: "i1", episode_id: "e", attempt_id: "a",
                 decision_digest: "d", episode: {})
    end
  end

  # --- T5.4: situation-scoped retrieval --------------------------------------

  def memory_engine
    directory = Dir.mktmpdir("tamoz-learning-loop")
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "memory.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    clock = Time.at(1_700_000_000)
    engine = Tamoz::Agent::Memory::Engine.new(
      tenant: "acme", adapter:, protection: nil, clock: -> { clock }
    )
    [engine, adapter, directory]
  end

  def situation_snapshot(entity_id: "c-02")
    {
      "situation_id" => "sit-2", "situation_version" => 8,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => entity_id},
      "facts" => {"pressure" => 0.5}
    }
  end

  def reference_for(episode_id: "s1", attempt_id: "at-1")
    {
      "outcome_id" => "out-1", "outcome_digest" => "sha256:#{"c" * 64}",
      "command_id" => "cmd-1", "decision_id" => "decision-1",
      "source_authority" => "stream-1",
      "reconciliation_version" => "1", "observation_status" => "verified",
      "episode_id" => episode_id, "attempt_id" => attempt_id
    }
  end

  def admit_situation_episode(engine, entity_id: "c-01", statement: "fouling signature")
    episode = {
      session_id: "s1", episode_id: "s1", attempt_id: "at-1",
      statement:, task: "diagnose compressor",
      plan_digest: "sha256:#{"p" * 64}",
      completed_at: 1_700_000_000,
      scopes: {
        "tenant" => "acme", "user" => "stream", "project" => "stream",
        "situation_type" => "equipment",
        "entity_type" => "compressor", "entity_id" => entity_id
      },
      sensitivity: :internal,
      decisions: ["fouling"], corrections: [],
      observed_outcome: {"outcome" => "confirmed", "confidence" => 0.9}
    }
    result = engine.admission.admit_episode(
      episode:, owner: "stream",
      reconciled_outcome: reference_for, verify_source_authority: ->(reference) { reference.fetch("source_authority") == "stream-1" }
    )
    assert result.accepted?
    assert_equal :observed, result.record.epistemic_kind
    result.record
  end

  def test_a_related_entity_retrieves_the_first_occurrence_within_the_boundary
    engine, adapter, directory = memory_engine
    admit_situation_episode(engine, entity_id: "c-01")

    caller = {
      tenant: "acme", user: "stream", project: "stream",
      sensitivity: "internal",
      compatibility_graph: "1", compatibility_behavior: "tamoz.agent.session/1"
    }
    result = SituationMemory.related(
      repository: engine.repository, caller:,
      snapshot: situation_snapshot(entity_id: "c-02")
    )
    assert_equal 1, result.fetch(:candidates).length,
                 "a second occurrence on a related entity (same tenant, same " \
                 "entity type) retrieves the first occurrence's Experience"
    assert_equal "c-01", result.fetch(:candidates).fetch(0).fetch("scopes_entity_id")
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_out_of_boundary_entities_retrieve_nothing
    engine, adapter, directory = memory_engine
    admit_situation_episode(engine, entity_id: "c-01")

    caller = {
      tenant: "acme", user: "stream", project: "stream",
      sensitivity: "internal",
      compatibility_graph: "1", compatibility_behavior: "tamoz.agent.session/1"
    }
    foreign = SituationMemory.retrieve(
      repository: engine.repository, caller:,
      snapshot: situation_snapshot(entity_id: "c-01").merge(
        "entity" => {"type" => "fan", "id" => "f-01"}
      )
    )
    assert_empty foreign.candidates,
                 "a different entity type is outside the relatedness boundary"

    other_tenant = SituationMemory.retrieve(
      repository: engine.repository,
      caller: caller.merge(tenant: "other"),
      snapshot: situation_snapshot
    )
    assert_empty other_tenant.candidates,
                 "a different tenant is outside the relatedness boundary"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # --- T5.3: admission requires the authenticated reference -------------------

  def test_a_claimed_reference_that_does_not_verify_is_refused
    engine, adapter, directory = memory_engine
    episode = {
      session_id: "s1", episode_id: "s1", attempt_id: "at-1",
      statement: "learned", task: "t", plan_digest: "sha256:#{"p" * 64}",
      completed_at: 1, scopes: {"tenant" => "acme", "user" => "stream", "project" => "stream"},
      sensitivity: :internal, decisions: [], corrections: [],
      observed_outcome: {"outcome" => "confirmed", "confidence" => 0.9}
    }

    forged = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: reference_for, verify_source_authority: ->(_reference) { false }
      )
    end
    assert_includes forged.message, "forged_source_authority"

    unlearnable = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: reference_for.merge("observation_status" => "inconclusive"),
        verify_source_authority: ->(_reference) { true }
      )
    end
    assert_includes unlearnable.message, "unlearnable_verdict"

    foreign = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: reference_for.merge("episode_id" => "s9"),
        verify_source_authority: ->(_reference) { true }
      )
    end
    assert_includes foreign.message, "foreign_episode"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # The verifier interface contract (security-audit finding): the callable
  # receives the WHOLE normalized reference — so production can bind an HMAC
  # or signature over all eight fields — and a RAISING verifier is a forgery,
  # never a crash.
  def test_the_verifier_sees_the_whole_reference_and_a_raising_verifier_refuses
    engine, adapter, directory = memory_engine
    episode = {
      session_id: "s1", episode_id: "s1", attempt_id: "at-1",
      statement: "learned", task: "t", plan_digest: "sha256:#{"p" * 64}",
      completed_at: 1, scopes: {"tenant" => "acme", "user" => "stream", "project" => "stream"},
      sensitivity: :internal, decisions: [], corrections: [],
      observed_outcome: {"outcome" => "confirmed", "confidence" => 0.9}
    }
    seen = nil
    result = engine.admission.admit_episode(
      episode:, owner: "stream",
      reconciled_outcome: reference_for,
      verify_source_authority: lambda do |reference|
        seen = reference
        reference.fetch("source_authority") == "stream-1"
      end
    )
    assert result.accepted?
    assert_equal :observed, result.record.epistemic_kind
    assert_equal "out-1", seen.fetch("outcome_id"),
                 "the verifier must see the WHOLE reference, not just the authority name"
    assert_equal "verified", seen.fetch("observation_status")

    raising = assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      engine.admission.admit_episode(
        episode:, owner: "stream",
        reconciled_outcome: reference_for,
        verify_source_authority: ->(_reference) { raise "verifier boom" }
      )
    end
    assert_includes raising.message, "forged_source_authority",
                    "a raising verifier is a forgery, never a crash"
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  # --- The loop closed: produced episode -> awaiting -> reconciled -> admission

  def test_a_produced_episode_feeds_a_late_outcome_into_admission
    directory = Dir.mktmpdir("tamoz-loop-e2e")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    memory_adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "memory.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    engine = Tamoz::Agent::Memory::Engine.new(
      tenant: "acme", adapter: memory_adapter, protection: nil,
      clock: -> { Time.at(1_700_000_000) }
    )
    verification = VerificationStore.new(clock: -> { Time.at(1_700_000_000) })

    graph = Tamoz.graph(name: "episode-learn", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      state :summary, default: nil
      state :facts_used, default: []
      state :alternatives, default: []
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 4, output_tokens: 2}})
        {
          primary_hypothesis: "bearing wear", confidence: 0.9,
          summary: "pressure trend confirms bearing wear",
          facts_used: [{"pressure" => 0.9}],
          alternatives: []
        }
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
    app = graph.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil, verification_store: verification
    )

    snapshot = {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.9}
    }
    wire = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-learn", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      allowed_intent_types: ["create_maintenance_ticket"],
      capability_token: "opaque.hmac.token",
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot)
    )
    events = runner.run(wire).each.to_a
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    decision_event = events.find { |event| event.decision != nil }
    decision = JSON.parse(decision_event.decision.decision_json)
    intent_id = decision.fetch("intents").fetch(0).fetch("intent_id")
    row = verification.fetch(intent_id:)
    assert_equal :awaiting, row.state,
                 "a produced consequential episode opens an awaiting verification"

    # Days later, Channel B delivers recorded then reconciled.
    handler_store = verification
    admitted = nil
    handlers = {
      "io.agenticstream.outcome.recorded.v1" => lambda do |event|
        data = event.data
        handler_store.record_outcome(
          intent_id: data.fetch("intent_id"),
          outcome_id: data.fetch("outcome_id"),
          outcome_digest: data.fetch("outcome_digest"),
          command_id: data["command_id"]
        )
      end,
      "io.agenticstream.outcome.reconciled.v1" => lambda do |event|
        data = event.data
        handler_store.reconcile(
          intent_id: data.fetch("intent_id"),
          verdict: data.fetch("verdict"),
          reconciliation_version: data.fetch("reconciliation_version"),
          source_authority: data.fetch("source_authority")
        )
        row = handler_store.fetch(intent_id: data.fetch("intent_id"))
        unless row.learnable?
          admitted = false
          next
        end
        result = engine.admission.admit_episode(
          episode: row.episode.merge(
            observed_outcome: {
              "outcome" => data.fetch("outcome"),
              "confidence" => data.fetch("confidence", 0.9)
            }
          ),
          owner: "stream",
          reconciled_outcome: handler_store.reference(intent_id: data.fetch("intent_id")),
          verify_source_authority: ->(reference) { reference.fetch("source_authority") == "stream-1" }
        )
        admitted = result.accepted? ? result.record : false
      end
    }
    cursor = MemoryCursorStore.new
    subscriber = Subscriber.new(cursor_store: cursor, handlers:, credential: "out-cred")
    subscriber.run(transport: ScriptedTransport.new(frames: [
      event_frame("1", "io.agenticstream.outcome.recorded.v1", "evt-1", data: {
        "intent_id" => intent_id, "outcome_id" => "out-9",
        "outcome_digest" => "sha256:#{"o" * 64}", "command_id" => "cmd-7"
      }),
      event_frame("2", "io.agenticstream.outcome.reconciled.v1", "evt-2", data: {
        "intent_id" => intent_id, "verdict" => "verified",
        "reconciliation_version" => "1", "source_authority" => "stream-1",
        "outcome" => "cleaned and confirmed"
      })
    ]))

    closed = verification.fetch(intent_id:)
    assert_equal :reconciled, closed.state
    assert closed.learnable?
    refute_nil admitted, "the reconciled outcome must admit the Experience"
    assert_equal :observed, admitted.epistemic_kind
    provenance = admitted.source_refs.find { |ref| ref.key?("command_id") }
    assert_equal "cmd-7", provenance.fetch("command_id")
    assert_equal decision.fetch("decision_id"), provenance.fetch("decision_id")
    assert_equal "out-9", provenance.fetch("identity").split(":").last
    assert_equal "2", cursor.cursor, "both outcome frames are acknowledged"
  ensure
    adapter&.close
    memory_adapter&.close
    FileUtils.remove_entry(directory) if directory
  end
end
