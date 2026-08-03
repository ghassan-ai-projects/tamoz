# frozen_string_literal: true

require_relative "test_helper"

# P14 critic-round fixes:
# - WallClock advances in live mode (the idle watermark can fire).
# - Outbox id length is enforced at BUILD time, never at enqueue (plan C9).
# - drain_outbox maps each Situation to its own thread namespace (C7), so the
#   graph's single-fenced-writer rule enforces one episode per Situation.
# - The cognition evaluator decides the persisted trigger outcome (the
#   trigger table is read-visible, not write-only).
class SQLiteStreamCriticFixTest < Minitest::Test
  Stream = Tamoz::Stream

  def with_engine
    Dir.mktmpdir("tamoz-stream-critic") do |directory|
      path = File.join(directory, "stream.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: "stream-critic", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "stream-critic.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        app = definition.compile(checkpointer: adapter)
        store = adapter.bind_stream_store
        yield store, adapter, app, path
      ensure
        adapter&.close
      end
    end
  end

  def envelope(value: 30.0, **overrides)
    Stream::EventEnvelope.new(
      event_id: "evt-1", event_type: "temperature", schema_id: "temperature.v2",
      payload: {"measured_at" => 1_700_000_000, "value" => value},
      tenant_id: "tenant-1", source_id: "device-428",
      channel_id: "factory-1.temperature", channel_revision: 7,
      partition_key: "p", entity_id: "device-428",
      event_time: 1_700_000_000, observed_time: 1_700_000_001,
      ingestion_time: 1_700_000_002, **overrides
    )
  end

  def operators
    {
      reduce: lambda do |events, state, _clock|
        history = (state.fetch("history", []) + events.map { |e| e.payload.fetch("value") }).last(4)
        [{"history" => history}, {"sum" => history.sum}]
      end,
      situation: lambda do |state, result, _clock, new_events|
        return nil if state.fetch("history", []).empty? || new_events.empty?

        {"situation_id" => "temp.anomaly", "phase" => "monitoring",
         "facts" => {"sum" => result.fetch("sum")}, "hypotheses" => {},
         "confidence" => 0.8, "evidence" => [], "completeness" => "on_time",
         "source_versions" => [], "payload_digest" => "sha256:#{"a" * 64}"}
      end,
      trigger: lambda do |situation, _clock|
        {"trigger_id" => "trig.#{situation.fetch("version")}",
         "scores" => {"anomaly" => 0.6}, "evidence" => [], "reasons" => [],
         "completeness" => "on_time", "cost_estimate" => 10, "freshness" => 0,
         "deadline" => 1_700_000_060, "outcome" => "admitted"}
      end,
      outbox: lambda do |situation, _clock|
        return [] unless situation

        [{"outbox_id" => "obx.#{situation.fetch("version")}",
          "kind" => "situation_admission",
          "payload" => {"situation_id" => "temp.anomaly",
                        "version" => situation.fetch("version")}}]
      end
    }
  end

  # The live WallClock must ADVANCE so the idle-watermark mechanism can fire
  # (a frozen clock would freeze global progress, design §7/P4).
  def test_wall_clock_advances_in_live_mode
    clock = Stream::WallClock.new(now: 1_700_000_000)
    first = clock.now_processing
    sleep 0.05
    second = clock.now_processing
    assert_operator second, :>=, first
    # It is monotonic and never regresses.
    assert_operator clock.now_processing, :>=, second
  end

  # An oversized outbox id fails at BUILD time (append), never at enqueue —
  # plan C9.
  def test_oversized_outbox_id_fails_at_build_time
    with_engine do |store, _adapter, _app, _path|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      bad_operators = operators.merge(
        outbox: lambda do |_situation, _clock|
          [{"outbox_id" => "x" * 400, "kind" => "situation_admission",
            "payload" => {"situation_id" => "temp.anomaly"}}]
        end
      )
      error = assert_raises(Stream::RequestIdTooLongError) do
        store.process_partition("p", batch: [envelope], clock:, operators: bad_operators,
                                      spec_digest: "sha256:#{"b" * 64}")
      end
      assert_includes error.message, "request-id bound"
    end
  end

  # C7: drain_outbox maps each Situation to its OWN thread namespace, so the
  # graph's single-fenced-writer rule enforces one episode per Situation.
  def test_drain_outbox_uses_the_situation_namespace
    with_engine do |store, _adapter, app, _path|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      store.process_partition("p", batch: [envelope], clock:, operators:,
                                   spec_digest: "sha256:#{"b" * 64}")
      drained = store.drain_outbox(checkpoints: app.checkpointer, clock:)
      assert_equal 1, drained.length
      request = app.checkpointer.fetch_request(
        thread_id: "situation.temp.anomaly",
        request_id: "obx.1"
      )
      assert_equal :queued, request.status,
                   "the request must land in the situation-scoped thread namespace"
    end
  end

  # The cognition evaluator decides the PERSISTED trigger outcome, and the
  # trigger table is read-visible.
  def test_cognition_spec_decides_the_persisted_outcome
    with_engine do |store, _adapter, _app, _path|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      spec = Stream::SituationSpec.new(
        spec_id: "temp.anomaly", schema_id: "temperature.v2",
        risk_class: :r1_notify, max_confidence: 0.5, freshness_seconds: 30,
        deadline_seconds: 60, debounce_seconds: 5, cooldown_seconds: 60,
        max_cost_estimate: 100
      )
      store.process_partition(
        "p", batch: [envelope], clock:, operators:, spec_digest: spec.spec_digest,
        cognition_spec: spec
      )
      # The operator claimed "admitted", but the evaluator rejects it: the
      # anomaly score 0.6 exceeds max_confidence 0.5.
      outcomes = store.trigger_outcomes("temp.anomaly")
      assert_equal 1, outcomes.length
      assert_equal "rejected", outcomes.first.fetch("outcome")
    end
  end
end
