# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "tamoz/stream/outcome_subscriber"
require "tamoz/stream/verification_store"
require "tamoz/stream/situation_memory"
require "support/local_model_endpoint"
require "support/episode_composition"

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

  class ApprovalRelayDouble
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver(approval:, conversation_id:)
      @deliveries << {approval:, conversation_id:}
      {"message_id" => "approval-message-1"}
    end
  end

  class MemoryCursorStore
    attr_reader :cursor, :events

    def initialize
      @cursor = nil
      @events = {}
    end

    def read = @cursor

    def write(value) = @cursor = value

    def event_state(source:, event_id:, payload_digest:)
      stored = @events[[source, event_id]]
      return :new unless stored

      stored.fetch("payload_digest") == payload_digest ? :same : :conflict
    end

    def mark_event(source:, event_id:, payload_digest:, traceparent: nil, tracestate: nil)
      state = event_state(source:, event_id:, payload_digest:)
      raise "notification payload conflicts with its durable event id" if state == :conflict

      @events[[source, event_id]] ||= {
        "payload_digest" => payload_digest,
        "traceparent" => traceparent,
        "tracestate" => tracestate
      }
    end
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

  def notification_frame(cursor, type, id, data:)
    source = data.fetch("source_authority")
    envelope = {
      "specversion" => "1.0", "id" => id, "source" => source, "type" => type,
      "subject" => "outcome/#{data.fetch("outcome_id")}",
      "time" => "2026-08-14T12:00:00Z", "datacontenttype" => "application/json",
      "dataschema" => Tamoz::Stream::NotificationContract::CONTRACT_ID,
      "data" => data, "tenantid" => data.fetch("tenant_id"),
      "partitionkey" => data.fetch("command_id"),
      "ingestedtime" => "2026-08-14T12:00:01Z",
      "envelopedigest" => "sha256:#{"e" * 64}", "classification" => "internal"
    }
    Frame.new(type: :event, cursor:, event: type, data: JSON.generate(envelope), control: nil)
  end

  def durable_event_digest(frame)
    Tamoz::Core.digest("tamoz/stream/notification/v1\n", JSON.parse(frame.data))
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
    subscriber = Subscriber.new(
      cursor_store: store, handlers:, credential: "c"
    )
    subscriber.run(transport:)

    assert_equal ["evt-1"], calls, "a redelivered event is deduplicated"
    assert_empty subscriber.skipped
    assert_equal "11", store.cursor, "the cursor advances past both frames"
  end

  def test_durable_event_digest_deduplicates_and_rejects_conflicting_payloads
    store = MemoryCursorStore.new
    calls = []
    handlers = {"io.agenticstream.test.v1" => ->(event) { calls << event.data }}
    first_frame = event_frame("10", "io.agenticstream.test.v1", "evt-1", data: {"value" => "one"})
    same_frame = event_frame("11", "io.agenticstream.test.v1", "evt-1", data: {"value" => "one"})
    conflicting_frame = event_frame("12", "io.agenticstream.test.v1", "evt-1", data: {"value" => "two"})

    Subscriber.new(cursor_store: store, handlers:, credential: "c").run(
      transport: ScriptedTransport.new(frames: [first_frame])
    )
    assert_equal [{"value" => "one"}], calls
    assert_equal 1, store.events.length, "the fresh event is durably marked"
    assert_equal :same, store.event_state(
      source: "stream-1", event_id: "evt-1", payload_digest: durable_event_digest(first_frame)
    )

    Subscriber.new(cursor_store: store, handlers:, credential: "c").run(
      transport: ScriptedTransport.new(frames: [same_frame])
    )
    assert_equal [{"value" => "one"}], calls, "a durable same-payload redelivery is deduplicated"
    assert_equal "11", store.cursor

    conflicting = Subscriber.new(
      cursor_store: store, handlers:, credential: "c", max_poison_retries: 1
    )
    2.times do
      conflicting.run(transport: ScriptedTransport.new(frames: [conflicting_frame]))
    end
    assert_equal :conflict, store.event_state(
      source: "stream-1", event_id: "evt-1",
      payload_digest: durable_event_digest(conflicting_frame)
    )
    assert_match(/notification id was redelivered with a different payload/,
                  conflicting.skipped.fetch(0).fetch(:reason))
    assert_equal [{"value" => "one"}], calls, "a conflicting redelivery is never dispatched"
  end

  def test_approval_request_delivers_once_and_records_a_durable_receipt
    directory = Dir.mktmpdir("tamoz-approval-handler")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    durable = adapter.bind_durable_subscriber_store(tenant: "acme")
    receipts = adapter.bind_approval_receipt_store(tenant: "acme")
    relay = ApprovalRelayDouble.new
    envelope = read_json(
      ROOT.join("gems", "tamoz-stream", "contracts", "notification-goldens-v1.json")
    ).fetch("events").find { |candidate| candidate.fetch("type") == "io.agenticstream.approval.requested.v1" }
    event = Subscriber::CloudEvent.new(
      id: envelope.fetch("id"), source: envelope.fetch("source"), type: envelope.fetch("type"),
      data: envelope.fetch("data"), time: envelope.fetch("time"),
      traceparent: envelope["traceparent"], tracestate: envelope["tracestate"], envelope:
    )
    handlers = Tamoz::Stream::LiveLearningHandlers.new(
      verification: nil, memory: nil, durable:, tenant: "acme", logger: nil,
      approval_receipts: receipts, approval_relay: relay, conversation_id: "chat-1"
    ).callables

    2.times { handlers.fetch(event.type).call(event) }

    assert_equal 1, relay.deliveries.length
    assert_equal envelope.fetch("data"), relay.deliveries.fetch(0).fetch(:approval)
    assert_equal "chat-1", relay.deliveries.fetch(0).fetch(:conversation_id)
    assert_equal({"message_id" => "approval-message-1"},
                 receipts.fetch("appr_1").fetch("delivery_receipt"))
    assert_equal false, receipts.fetch("appr_1").fetch("delivery_claimed")
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
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
      tenant_id: "acme",
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      episode_id: "ep-1", attempt_id: "at-1",
      decision_digest: "sha256:#{"d" * 64}",
      episode: {task: "t"}, decision_id: "decision-7"
    )
    assert_equal :awaiting,
                 store.fetch(tenant_id: "acme", intent_id: "intent.ep-1.at-1.1.maintenance.ticket").state

    store.record_outcome(
      tenant_id: "acme",
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      outcome_id: "out-9", outcome_digest: "sha256:#{"b" * 64}",
      command_id: "cmd-7"
    )
    store.reconcile(
      tenant_id: "acme",
      intent_id: "intent.ep-1.at-1.1.maintenance.ticket",
      command_id: "cmd-7", outcome_id: "out-9", outcome_digest: "sha256:#{"b" * 64}",
      verdict: "verified", reconciliation_version: 1, source_authority: "stream-1"
    )

    row = store.fetch(tenant_id: "acme", intent_id: "intent.ep-1.at-1.1.maintenance.ticket")
    assert_equal :reconciled, row.state
    assert row.learnable?
    reference = store.reference(tenant_id: "acme", intent_id: "intent.ep-1.at-1.1.maintenance.ticket")
    assert_equal "out-9", reference.fetch("outcome_id")
    assert_equal "verified", reference.fetch("observation_status")
    assert_equal "cmd-7", reference.fetch("command_id")
    assert_equal "decision-7", reference.fetch("decision_id")
  end

  def test_unlearnable_verdicts_are_recorded_and_never_learned_from
    store = VerificationStore.new(clock: -> { Time.at(1_700_000_000) })
    intent = "intent.ep-1.at-1.1.maintenance.ticket"
    store.open(tenant_id: "acme", intent_id: intent, episode_id: "ep-1", attempt_id: "at-1",
               decision_digest: "sha256:#{"d" * 64}", episode: {}, decision_id: "decision-7")
    store.record_outcome(tenant_id: "acme", intent_id: intent, outcome_id: "out-9",
                         outcome_digest: "sha256:#{"b" * 64}", command_id: "cmd-7")
    store.reconcile(tenant_id: "acme", intent_id: intent, command_id: "cmd-7",
                    outcome_id: "out-9", outcome_digest: "sha256:#{"b" * 64}",
                    verdict: "inconclusive", reconciliation_version: 1,
                    source_authority: "stream-1")

    row = store.fetch(tenant_id: "acme", intent_id: intent)
    assert_equal :reconciled, row.state
    refute row.learnable?
    assert_nil store.reference(tenant_id: "acme", intent_id: intent),
               "an inconclusive verdict must never feed admission"
  end

  def test_duplicate_verification_open_is_idempotent
    store = VerificationStore.new
    store.open(tenant_id: "acme", intent_id: "i1", episode_id: "e", attempt_id: "a",
               decision_digest: "sha256:#{"d" * 64}", episode: {}, decision_id: "decision-1")
    assert_same store, store.open(
      tenant_id: "acme", intent_id: "i1", episode_id: "e", attempt_id: "a",
      decision_digest: "sha256:#{"d" * 64}", episode: {}, decision_id: "decision-1"
    )
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

  def situation_recaller(engine)
    Tamoz::Agent::Memory::SituationRecaller.new(engine:)
  end

  def recall_caller(engine)
    engine.caller(
      user: "stream", project: "stream", sensitivity: :internal,
      compatibility: {graph_version: "1", behavior_version: "tamoz.agent.session/1"}
    )
  end

  def reference_for(episode_id: "s1", attempt_id: "at-1")
    {
      "outcome_id" => "out-1", "outcome_digest" => "sha256:#{"c" * 64}",
      "command_id" => "cmd-1", "decision_id" => "decision-1",
      "source_authority" => "stream-1",
      "reconciliation_version" => 1, "observation_status" => "verified",
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

    caller = recall_caller(engine)
    result = SituationMemory.related(
      recaller: situation_recaller(engine), caller:,
      snapshot: situation_snapshot(entity_id: "c-02")
    )
    assert_equal 1, result.records.length,
                 "a second occurrence on a related entity (same tenant, same " \
                 "entity type) retrieves the first occurrence's Experience"
    assert_equal "c-01", result.records.fetch(0).scopes.fetch("entity_id")
  ensure
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_out_of_boundary_entities_retrieve_nothing
    engine, adapter, directory = memory_engine
    admit_situation_episode(engine, entity_id: "c-01")

    caller = recall_caller(engine)
    recaller = situation_recaller(engine)
    foreign = SituationMemory.retrieve(
      recaller:, caller:,
      snapshot: situation_snapshot(entity_id: "c-01").merge(
        "entity" => {"type" => "fan", "id" => "f-01"}
      )
    )
    assert_empty foreign.records,
                 "a different entity type is outside the relatedness boundary"

    assert_raises(Tamoz::Agent::Memory::MemoryPolicyError) do
      SituationMemory.retrieve(
        recaller:, caller: caller.merge(tenant: "other"), snapshot: situation_snapshot
      )
    end
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
    memory_adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "memory.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    engine = Tamoz::Agent::Memory::Engine.new(
      tenant: "acme", adapter: memory_adapter, protection: nil,
      clock: -> { Time.at(1_700_000_000) }
    )
    verification = VerificationStore.new(clock: -> { Time.at(1_700_000_000) })

    # P1: the fixed graph produces the decision; the verification row is no
    # longer opened by the runner (that moved to the Go side) — the test opens
    # it explicitly, as the runtime's subscriber path does.
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: [Tamoz::Core.jcs(
        AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
      )],
      log_path: File.join(directory, "endpoint.log")
    ).start
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)

    snapshot = AquacultureDomain.snapshot
    wire = EpisodeComposition.wire_request(
      episode_id: "ep-learn",
      snapshot:,
      allowed_intent_types: ["install_watch_condition", "start_aerator"]
    )
    events = []
    composition.fetch(:runner).run(wire).each { |event| events << event }
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    decision_event = events.find { |event| event.decision != nil }
    decision = JSON.parse(decision_event.decision.decision_json)
    intent = decision.fetch("intents").fetch(0)
    verification.open(
      tenant_id: "acme",
      intent_id: intent.fetch("intent_id"),
      episode_id: "ep-learn",
      attempt_id: "at-1",
      decision_digest: Tamoz::Core.normalize_digest(decision_event.decision.decision_sha256),
      episode: {
        "session_id" => "ep-learn",
        "episode_id" => "ep-learn",
        "attempt_id" => "at-1",
        "task" => "stream episode ep-learn attempt at-1",
        "plan_digest" => Tamoz::Core.normalize_digest(decision_event.decision.decision_sha256),
        "completed_at" => Time.at(1_700_000_000).to_i,
        "traceparent" => nil,
        "tracestate" => nil,
        "scopes" => {
          "tenant" => "acme", "user" => "stream", "project" => "stream",
          "situation_type" => snapshot.fetch("situation_type"),
          "entity_type" => snapshot.fetch("entity").fetch("type"),
          "entity_id" => snapshot.fetch("entity").fetch("id")
        },
        "sensitivity" => :internal,
        "decisions" => [String(decision.fetch("primary_hypothesis", ""))],
        "corrections" => []
      },
      decision_id: intent.fetch("decision_id")
    )
    intent_id = intent.fetch("intent_id")
    row = verification.fetch(tenant_id: "acme", intent_id:)
    assert_equal :awaiting, row.state,
                 "a produced consequential episode opens an awaiting verification"

    # Days later, Channel B delivers recorded then reconciled through the live
    # handler wiring and the durable subscriber store.
    durable = memory_adapter.bind_durable_subscriber_store(tenant: "acme")
    logger = Struct.new(:messages) do
      def info(message) = messages << message
    end.new([])
    handlers = Tamoz::Stream::LiveLearningHandlers.new(
      verification:, memory: engine, durable:, tenant: "acme", logger:
    ).callables
    subscriber = Subscriber.new(cursor_store: durable, handlers:, credential: "out-cred")
    subscriber.run(transport: ScriptedTransport.new(frames: [
      notification_frame("1", "io.agenticstream.outcome.recorded.v1", "evt-1", data: {
        "tenant_id" => "acme", "intent_id" => intent_id, "outcome_id" => "out-9",
        "outcome_digest" => "sha256:#{"b" * 64}", "command_id" => "cmd-7",
        "status" => "succeeded", "reconciliation_status" => "observed", "source_authority" => "stream-1"
      }),
      notification_frame("2", "io.agenticstream.outcome.reconciled.v1", "evt-2", data: {
        "tenant_id" => "acme", "intent_id" => intent_id, "outcome_id" => "out-9",
        "outcome_digest" => "sha256:#{"b" * 64}", "command_id" => "cmd-7",
        "final_status" => "succeeded", "reconciliation_status" => "reconciled",
        "verdict" => "verified", "reconciliation_version" => 1, "source_authority" => "stream-1"
      })
    ]))

    assert_empty subscriber.skipped
    closed = verification.fetch(tenant_id: "acme", intent_id:)
    assert_equal :reconciled, closed.state
    assert closed.learnable?
    assert durable.admitted?(intent_id), "the admitted intent must be durably marked"
    assert_equal "2", durable.read, "both outcome frames are acknowledged"

    index_rows = memory_adapter.pool.with_connection do |connection|
      connection.execute(
        "SELECT layer, memory_id FROM tamoz_memory_index WHERE store_namespace = ?",
        [engine.namespace]
      )
    end
    assert_equal 1, index_rows.length, "the reconciled outcome admits exactly one Experience"
    layer, memory_id = index_rows.fetch(0)
    admitted = engine.repository.fetch(
      engine.namespace, layer, memory_id
    ).fetch(:entry).value
    assert_equal :observed, admitted.epistemic_kind
    provenance = admitted.source_refs.find { |ref| ref.key?("command_id") }
    assert_equal "cmd-7", provenance.fetch("command_id")
    assert_equal decision.fetch("decision_id"), provenance.fetch("decision_id")
    assert_equal "out-9", provenance.fetch("identity").split(":").last
  ensure
    endpoint&.stop
    composition&.fetch(:adapter)&.close
    memory_adapter&.close
    FileUtils.remove_entry(directory) if directory
  end
end
