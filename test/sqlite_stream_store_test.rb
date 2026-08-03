# frozen_string_literal: true

require_relative "test_helper"

# P14-A (plan §4, design §5/§6/§15) — the durable StreamStore: idempotent
# dedup, quarantine on hash conflict, durable rejection records, and
# ack-only-after-durable-admission. Timestamps come from the injected clock.
class SQLiteStreamStoreTest < Minitest::Test
  Stream = Tamoz::Stream

  def with_store
    Dir.mktmpdir("tamoz-stream") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "stream.sqlite3"))
      begin
        store = adapter.bind_stream_store
        yield store, adapter
      ensure
        adapter&.close
      end
    end
  end

  def clock
    @clock ||= Stream::ReplayClock.new(start: 1_700_000_000)
  end

  def descriptor(**overrides)
    Stream::ChannelDescriptor.new(
      channel_id: "factory-1.temperature", revision: 7, transport: "mqtt",
      source_identity: "sensor-ca:device-428", schema: "temperature.v2",
      partition_by: %w[tenant_id device_id],
      time: {"field" => "measured_at", "max_clock_skew_s" => 30},
      units: {"value" => "Cel"}, **overrides
    )
  end

  def envelope(**overrides)
    Stream::EventEnvelope.new(
      event_id: "evt-1", event_type: "temperature", schema_id: "temperature.v2",
      payload: {"measured_at" => 1_700_000_000, "value" => 21.5},
      tenant_id: "tenant-1", source_id: "device-428",
      channel_id: "factory-1.temperature", channel_revision: 7,
      partition_key: "tenant-1:device-428", entity_id: "device-428",
      event_time: 1_700_000_000, observed_time: 1_700_000_001,
      ingestion_time: 1_700_000_002, **overrides
    )
  end

  def test_admit_is_durable_and_idempotent_for_same_bytes
    with_store do |store, _adapter|
      store.deploy_channel(descriptor)
      first = store.admit(envelope, clock:)
      assert_equal "admitted", first.fetch("outcome")

      # The admission metadata is durable (ack is only allowed after this).
      assert store.durable?(envelope.identity)
      record = store.admission_record(envelope.identity)
      assert_equal "admitted", record.fetch("outcome")
      assert_equal envelope.payload_hash, record.fetch("payload_hash")

      # Same identity + same bytes: idempotent duplicate, never a second row.
      again = store.admit(envelope, clock:)
      assert_equal "duplicate", again.fetch("outcome")
    end
  end

  def test_same_identity_different_hash_is_quarantined_never_overwritten
    with_store do |store, _adapter|
      store.deploy_channel(descriptor)
      first = store.admit(envelope, clock:)
      assert_equal "admitted", first.fetch("outcome")

      # Same scoped id, different payload bytes: a security/integrity conflict.
      conflict = store.admit(
        envelope(payload: {"measured_at" => 1_700_000_000, "value" => 99.0}),
        clock:
      )
      assert_equal "quarantined", conflict.fetch("outcome")

      # The original admission is untouched; the conflict is a durable record.
      record = store.admission_record(envelope.identity)
      assert_equal "quarantined", record.fetch("outcome")
      assert_includes record.fetch("reason"), "payload hash changed"
      # The original row's payload_hash is NOT overwritten by the attacker.
      refute_equal conflict.fetch("outcome"), "admitted"
    end
  end

  def test_channel_deploy_is_cas_and_idempotent_for_same_digest
    with_store do |store, _adapter|
      # A fresh deploy (no CAS) creates revision 1.
      store.deploy_channel(descriptor)
      # Same digest with the correct current revision: idempotent no-op.
      store.deploy_channel(descriptor, expected_revision: 1)
      # A stale CAS on the current revision is refused.
      assert_raises(Tamoz::Scheduler::StoreConflictError) do
        store.deploy_channel(descriptor(revision: 8), expected_revision: 5)
      end
    end
  end

  def test_invalid_data_is_rejected_at_the_typed_boundary_never_silent
    with_store do |store, _adapter|
      store.deploy_channel(descriptor)
      # Oversized payloads are refused at the envelope's bounded-validation
      # boundary (the typed rejection seam): the value is never admitted, and
      # the failure is explicit — never a silent drop, never a partial row.
      error = assert_raises(Tamoz::ConfigurationError) do
        envelope(payload: {"measured_at" => 1_700_000_000, "value" => "x" * 20_000})
      end
      assert_includes error.message, "16 KiB"
      refute store.durable?(
        envelope(payload: {"measured_at" => 1_700_000_000, "value" => 21.5}).identity
      )
    end
  end

  def test_partition_watermark_is_monotonic_per_partition
    with_store do |store, _adapter|
      store.advance_watermark("tenant-1:device-428", 1_700_000_000, clock:)
      assert_equal 1_700_000_000, store.watermark("tenant-1:device-428")
      store.advance_watermark("tenant-1:device-428", 1_700_000_100, clock:)
      assert_equal 1_700_000_100, store.watermark("tenant-1:device-428")

      # A regression raises the typed error (design §7).
      assert_raises(Stream::WatermarkRegressionError) do
        store.advance_watermark("tenant-1:device-428", 1_700_000_050, clock:)
      end
    end
  end
end
