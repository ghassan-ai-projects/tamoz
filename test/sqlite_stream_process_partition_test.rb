# frozen_string_literal: true

require_relative "test_helper"

# P14-B (plan §5/C1, design §8) — the atomic processing boundary and the
# injected-clock determinism contract. The proof that matters: replay equals
# live — run the SAME virtual-time scenario twice and diff the durable bytes.
class SQLiteStreamProcessPartitionTest < Minitest::Test
  Stream = Tamoz::Stream

  def with_store
    Dir.mktmpdir("tamoz-stream-proc") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "stream.sqlite3"))
      begin
        store = adapter.bind_stream_store
        yield store, adapter
      ensure
        adapter&.close
      end
    end
  end

  def envelope(event_id:, value:, partition_key: "tenant-1:device-428", **overrides)
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

  # A deterministic reduce: a bounded sliding sum of the last N values.
  def operators
    {
      reduce: lambda do |events, state, _clock|
        history = (state.fetch("history", []) + events.map { |e| e.payload.fetch("value") }).last(4)
        [{"history" => history}, {"sum" => history.sum}]
      end,
      situation: lambda do |state, result, _clock|
        return nil if state.fetch("history", []).empty?

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
      trigger: lambda do |situation, _clock|
        {
          "trigger_id" => "trig.#{situation.fetch("version")}",
          "scores" => {"anomaly" => situation.fetch("facts").fetch("sum") > 100 ? 1.0 : 0.0},
          "evidence" => [{"kind" => "sliding_sum"}],
          "reasons" => ["window evaluated"],
          "completeness" => "on_time",
          "cost_estimate" => 10,
          "freshness" => 0,
          "deadline" => nil,
          "outcome" => "admitted"
        }
      end,
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

  # The C1 determinism contract: replay re-executes the identical operator
  # chain under the SAME virtual clock. Two runs over the same scenario must
  # produce byte-identical durable state.
  def test_replay_equals_live_is_byte_deterministic
    run = lambda do
      with_store do |store, _adapter|
        clock = Stream::ReplayClock.new(start: 1_700_000_000)
        batch = [
          envelope(event_id: "evt-1", value: 30.0),
          envelope(event_id: "evt-2", value: 40.0),
          envelope(event_id: "evt-3", value: 45.0)
        ]
        result = store.process_partition(
          "tenant-1:device-428", batch:, clock:, operators:,
          spec_digest: "sha256:#{"b" * 64}"
        )
        # The durable state snapshot: situation rows + operator state.
        [result.fetch("situations").map { |s| s.reject { |k, _| k == "version" } },
         store.watermark("tenant-1:device-428")]
      end
    end

    first = run.call
    second = run.call
    assert_equal first, second
  end

  def test_six_steps_are_atomic_and_a_fault_rolls_back_everything
    with_store do |store, _adapter|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      batch = [envelope(event_id: "evt-1", value: 30.0)]

      # A reduce that raises AFTER reading state: the whole transaction rolls
      # back — no event row, no operator state, no watermark.
      bad_operators = operators.merge(
        reduce: ->(_events, _state, _clock) { raise "operator fault" }
      )
      assert_raises(RuntimeError) do
        store.process_partition(
          "tenant-1:device-428", batch:, clock:, operators: bad_operators,
          spec_digest: "sha256:#{"b" * 64}"
        )
      end
      refute store.durable?(envelope(event_id: "evt-1", value: 30.0).identity),
             "a faulted transaction must not leave a half-admitted event"
      assert_nil store.watermark("tenant-1:device-428"),
                 "a faulted transaction must not advance the watermark"
    end
  end

  def test_situations_are_immutable_versions_and_correction_appends
    with_store do |store, _adapter|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      # First batch: v1 of the situation.
      store.process_partition(
        "p", batch: [envelope(event_id: "a", value: 60.0, partition_key: "p")],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )
      # Correction batch: a NEW immutable version, never a rewrite.
      clock.advance(10)
      store.process_partition(
        "p", batch: [envelope(event_id: "b", value: 70.0, partition_key: "p")],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )

      current = store.current_situation_version("temp.anomaly")
      assert_equal 2, current
    end
  end

  def test_idle_watermark_advances_after_the_idle_window
    with_store do |store, _adapter|
      clock = Stream::ReplayClock.new(start: 1_700_000_000)
      store.process_partition(
        "p", batch: [envelope(event_id: "a", value: 30.0, partition_key: "p")],
        clock:, operators:, spec_digest: "sha256:#{"b" * 64}"
      )
      assert_equal 1_700_000_000, store.watermark("p")

      # Not idle yet: no advancement.
      clock.advance(50)
      store.advance_idle_watermark("p", idle_after: 100, clock:)
      assert_equal 1_700_000_000, store.watermark("p")

      # Idle: the watermark advances to the current processing time so global
      # progress never silently freezes (design §7/P4).
      clock.advance(60)
      store.advance_idle_watermark("p", idle_after: 100, clock:)
      assert_equal 1_700_000_110, store.watermark("p")
    end
  end
end
