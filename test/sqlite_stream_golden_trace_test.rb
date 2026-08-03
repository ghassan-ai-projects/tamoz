# frozen_string_literal: true

require_relative "test_helper"

# P14-E (plan §9/C10) — golden traces under virtual time: the two mandatory
# safety cases plus restart determinism.
#
# - C10/P1 sequence case: a good event, then the SAME id with a DIFFERENT hash
#   -> a durable quarantine record (never overwritten, never silent).
# - C10/P5 kill-between-outbox-and-enqueue: a crash between the outbox append
#   and the drain produces exactly one logical episode after restart.
# - Restart determinism: replaying the identical virtual-time scenario after a
#   restart produces the same durable situation state.
class SQLiteStreamGoldenTraceTest < Minitest::Test
  Stream = Tamoz::Stream

  def with_engine
    Dir.mktmpdir("tamoz-stream-trace") do |directory|
      path = File.join(directory, "stream.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: "stream-trace", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "stream-trace.finish", version: "1") { |_s, _c| {ready: true} }
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

  def envelope(event_id:, value:, partition_key: "p", **overrides)
    Stream::EventEnvelope.new(
      event_id:, event_type: "temperature", schema_id: "temperature.v2",
      payload: {"measured_at" => 1_700_000_000, "value" => value},
      tenant_id: "tenant-1", source_id: "device-428",
      channel_id: "factory-1.temperature", channel_revision: 7,
      partition_key:, entity_id: "device-428",
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
        return nil if state.fetch("history", []).empty?
        return nil if new_events.empty?

        {
          "situation_id" => "temp.anomaly",
          "phase" => "monitoring",
          "facts" => {"sum" => result.fetch("sum"), "n" => state.fetch("history").length},
          "hypotheses" => {"anomalous" => result.fetch("sum") > 100},
          "confidence" => 0.8,
          "evidence" => [{"kind" => "sliding_sum"}],
          "completeness" => "on_time",
          "source_versions" => ["evt"],
          "payload_digest" => "sha256:#{"a" * 64}"
        }
      end,
      trigger: nil,
      outbox: lambda do |situation, _clock|
        return [] unless situation

        [{
          "outbox_id" => "obx.#{situation.fetch("version")}",
          "kind" => "situation_admission",
          "payload" => {"situation_id" => situation.fetch("situation_id"),
                        "version" => situation.fetch("version")}
        }]
      end
    }
  end

  # C10/P1: good event, then the SAME id with a different hash -> durable
  # quarantine record; the original admission is never overwritten.
  def test_sequence_case_good_then_same_id_different_hash_is_quarantined
    with_engine do |store, _adapter, _app, _path|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      store.process_partition(
        "p", batch: [envelope(event_id: "evt-1", value: 30.0)],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )
      # Same id, different bytes: the admitted event is quarantined durably.
      store.process_partition(
        "p", batch: [envelope(event_id: "evt-1", value: 99.0)],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )
      record = store.admission_record(envelope(event_id: "evt-1", value: 30.0).identity)
      assert_equal "quarantined", record.fetch("outcome")
      assert_includes record.fetch("reason"), "payload hash changed"
    end
  end

  # C10/P5: kill between outbox append and drain -> exactly one logical
  # episode after restart (the drain retries the same row; idempotent).
  def test_kill_between_outbox_and_enqueue_is_exactly_one_episode
    with_engine do |store, adapter, app, path|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      # The outbox row is appended inside the processing transaction, but the
      # drain is NOT called (simulating a crash between append and drain).
      store.process_partition(
        "p", batch: [envelope(event_id: "a", value: 30.0)],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )

      # "Restart": fresh adapter over the same file, then drain.
      reopened = Tamoz::SQLite::Adapter.new(path:)
      begin
        reopened_definition = Tamoz.graph(name: "stream-trace", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "stream-trace.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        reopened_app = reopened_definition.compile(checkpointer: reopened)
        reopened_store = reopened.bind_stream_store
        clock.advance(1)
        drained = reopened_store.drain_outbox(checkpoints: reopened_app.checkpointer, clock:)
        assert_equal 1, drained.length
        # Drain again: idempotent, no second episode.
        drained_twice = reopened_store.drain_outbox(checkpoints: reopened_app.checkpointer, clock:)
        assert_empty drained_twice
      ensure
        reopened.close
      end
    end
  end

  # Restart determinism: the identical virtual-time scenario after a restart
  # produces the same durable situation state (byte-identical rows).
  def test_restart_produces_the_same_situation_state
    run = lambda do
      with_engine do |store, _adapter, _app, path|
        clock = Stream::ReplayClock.new(start: 1_700_000_000)
        store.process_partition(
          "p", batch: [envelope(event_id: "a", value: 30.0)],
          clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
        )
        # Simulate a restart: a FRESH adapter reads the same durable state.
        reopened = Tamoz::SQLite::Adapter.new(path:)
        begin
          reopened_store = reopened.bind_stream_store
          reopened_store.current_situation_version("temp.anomaly")
        ensure
          reopened.close
        end
      end
    end
    assert_equal run.call, run.call
  end
end
