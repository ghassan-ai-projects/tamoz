# frozen_string_literal: true

require_relative "test_helper"

# T1.5 (PLAN_TAMOZ_STREAM_BUILD T1.5): the received situation snapshot is
# verified before any model call — digest recomputed with the shared rule and
# compared in constant time, identity fields required, malformed documents
# refused by the strict scanner.
class StreamSituationSnapshotTest < Minitest::Test
  def valid_snapshot(overrides = {})
    {
      "situation_id" => "sit-1",
      "situation_version" => 7,
      "tenant_id" => "acme",
      "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "observed_at" => "2026-08-12T00:00:00Z",
      "spec_digest" => "sha256:#{"d" * 64}",
      "facts" => {"pressure" => 1e-7, "temperature" => 18.4},
      "hypotheses" => ["bearing wear"],
      "confidence_floor" => 0.28,
      "event_horizon" => "2026-08-19T00:00:00Z"
    }.merge(overrides)
  end

  def snapshot_with_digest(overrides = {})
    value = valid_snapshot(overrides)
    digest = Tamoz::Core.digest(:snapshot, value)
    [Tamoz::Core.jcs(value), digest]
  end

  def test_a_verified_snapshot_returns_the_parsed_value
    json, digest = snapshot_with_digest
    parsed = Tamoz::Stream::ReceivedSnapshot.verify(json, digest)

    assert_equal "sit-1", parsed.fetch("situation_id")
    assert_equal "compressor", parsed.fetch("entity").fetch("type")
  end

  def test_a_tampered_snapshot_fails_before_any_model_call
    json, digest = snapshot_with_digest
    tampered = json.sub("c-01", "c-99")

    error = assert_raises(Tamoz::Stream::SnapshotDigestMismatchError) do
      Tamoz::Stream::ReceivedSnapshot.verify(tampered, digest)
    end
    assert_equal "stream_snapshot_digest_mismatch", error.class::CATEGORY
  end

  def test_a_wrong_digest_for_the_same_payload_is_refused
    json, = snapshot_with_digest
    other = Tamoz::Core.digest(
      :snapshot, valid_snapshot("entity" => {"type" => "compressor", "id" => "c-02"})
    )

    assert_raises(Tamoz::Stream::SnapshotDigestMismatchError) do
      Tamoz::Stream::ReceivedSnapshot.verify(json, other)
    end
  end

  def test_a_snapshot_missing_identity_fields_is_refused
    json, digest = snapshot_with_digest(
      "tenant_id" => nil, "entity" => {"type" => "", "id" => ""}
    )

    error = assert_raises(Tamoz::Stream::SnapshotIdentityError) do
      Tamoz::Stream::ReceivedSnapshot.verify(json, digest)
    end
    assert_equal "stream_snapshot_identity", error.class::CATEGORY
  end

  def test_an_empty_payload_is_refused
    assert_raises(Tamoz::Stream::SnapshotIdentityError) do
      Tamoz::Stream::ReceivedSnapshot.verify("", "sha256:#{"0" * 64}")
    end
  end

  def test_a_malformed_document_is_refused_by_the_strict_scanner
    json, digest = snapshot_with_digest
    malformed = json.sub("sit-1", "sit-1\"x") # unbalanced quote

    assert_raises(Tamoz::Core::JCS::Error) do
      Tamoz::Stream::ReceivedSnapshot.verify(malformed, digest)
    end
  end

  def test_the_digest_rule_agrees_with_the_shared_snapshot_vector
    vector = JSON.parse(
      File.read(ROOT.join("gems/tamoz-stream/contracts/canonicalization-vectors.json"),
                encoding: Encoding::UTF_8)
    ).fetch("accept").find { |entry| entry.fetch("name") == "snapshot-v1" }
    value = vector.fetch("input")

    assert Tamoz::Core.verify_digest(:snapshot, value, vector.fetch("digest"))
    parsed = Tamoz::Stream::ReceivedSnapshot.verify(
      Tamoz::Core.jcs(value), vector.fetch("digest")
    )
    assert_equal "sit_zone3_refrig_0091", parsed.fetch("situation_id")
  end
end
