# frozen_string_literal: true

require_relative "test_helper"

# P14-D/P14-B values (STREAMING_INPUT_DESIGN §5/§8/§9): the content-addressed
# ChannelDescriptor, the admitted EventEnvelope with scoped identity + payload
# hash (invariant 45), and the injected clocks (live WallClock / replay
# ReplayClock, monotonic).
class StreamValuesTest < Minitest::Test
  Stream = Tamoz::Stream

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

  def test_channel_descriptor_is_content_addressed_and_validated
    base = descriptor
    assert_equal 7, base.revision
    assert base.definition_digest.start_with?("sha256:")
    # A revision is a new digest only when the definition differs.
    assert_equal base.definition_digest, descriptor.definition_digest
    refute_equal base.definition_digest, descriptor(revision: 8).definition_digest

    assert_raises(Tamoz::ConfigurationError) { descriptor(channel_id: "Bad ID") }
    assert_raises(Tamoz::ConfigurationError) { descriptor(revision: 0) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(partition_by: []) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(delivery: :exactly_once) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(overflow: :silently_drop) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(time: {"field" => "x"}) }
  end

  def test_event_envelope_identity_and_payload_hash_are_deterministic
    one = envelope
    two = envelope
    assert_equal one.identity, two.identity
    assert_equal one.payload_hash, two.payload_hash

    # Same scoped id, different payload bytes -> different payload hash
    # (the quarantine discriminator, invariant 45).
    changed = envelope(payload: {"measured_at" => 1_700_000_000, "value" => 22.0})
    assert_equal one.identity, changed.identity
    refute_equal one.payload_hash, changed.payload_hash

    # Identity binds the channel revision: a new revision is a new identity.
    assert_ne_one = envelope(channel_revision: 8)
    refute_equal one.identity, assert_ne_one.identity

    assert_raises(Tamoz::ConfigurationError) { envelope(payload: {"x" => "y" * 20_000}) }
    assert_raises(Tamoz::ConfigurationError) { envelope(event_id: "") }
  end

  def test_clocks_are_monotonic_and_replay_is_injected
    replay = Stream::ReplayClock.new(start: 100)
    assert_equal 100, replay.now_processing
    assert_equal 105, replay.advance(5)
    assert_equal 105, replay.now_processing
    assert_raises(Stream::StreamClockError) { replay.advance(-1) }

    wall = Stream::WallClock.new(now: 1_700_000_000)
    assert_equal 1_700_000_000, wall.now_processing
    assert_raises(Stream::StreamClockError) { wall.advance(5) }
  end
end
