# frozen_string_literal: true

require_relative "test_helper"

# P14-C (plan §6/§7/C7/C10) — SituationSpec (deterministic compiled config,
# digest via the P8/P9 artifact pattern), the SituationSnapshot binding, and
# cognition admission with the eight outcomes including supersession/expiry
# rejection across the adversarial window. The bridge namespace mapping (C7)
# enforces one-episode-per-Situation at the graph layer.
class SituationCognitionTest < Minitest::Test
  Stream = Tamoz::Stream

  def spec(**overrides)
    Stream::SituationSpec.new(
      spec_id: "temp.anomaly", schema_id: "temperature.v2",
      risk_class: :r1_notify, max_confidence: 0.9, freshness_seconds: 30,
      deadline_seconds: 60, debounce_seconds: 5, cooldown_seconds: 60,
      max_cost_estimate: 100, **overrides
    )
  end

  def trigger(**overrides)
    {
      "trigger_id" => "trig.1",
      "situation_version" => 1,
      "scores" => {"anomaly" => 0.7},
      "evidence" => [{"kind" => "sliding_sum"}],
      "reasons" => ["window evaluated"],
      "completeness" => "on_time",
      "cost_estimate" => 10,
      "freshness" => 0,
      "deadline" => 1_700_000_060,
      "outcome" => "admitted",
      **overrides
    }
  end

  def test_situation_spec_is_content_addressed_and_validated
    base = spec
    assert base.spec_digest.start_with?("sha256:")
    assert_equal base.spec_digest, spec.spec_digest
    refute_equal base.spec_digest, spec(risk_class: :r2_bounded).spec_digest

    assert_raises(Tamoz::ConfigurationError) { spec(max_confidence: 1.5) }
    assert_raises(Tamoz::ConfigurationError) { spec(risk_class: :autonomous) }
    assert_raises(Tamoz::ConfigurationError) { spec(late_data_policy: :silent_drop) }
    assert_raises(Tamoz::ConfigurationError) { spec(debounce_seconds: 0) }
  end

  def test_snapshot_is_content_addressed_and_binds_the_situation_version
    one = Stream::SituationSnapshot.new(
      situation_id: "temp.anomaly", situation_version: 1,
      evidence: [{"kind" => "sliding_sum"}], uncertainty: 0.1,
      risk_class: :r1_notify, deadline: 1_700_000_060, created_at: 1_700_000_000
    )
    two = Stream::SituationSnapshot.new(
      situation_id: "temp.anomaly", situation_version: 1,
      evidence: [{"kind" => "sliding_sum"}], uncertainty: 0.1,
      risk_class: :r1_notify, deadline: 1_700_000_060, created_at: 1_700_000_000
    )
    assert_equal one.snapshot_digest, two.snapshot_digest

    # A NEW situation version is a NEW snapshot digest: a late Decision bound
    # to the old digest dies on the freshness check (C7).
    newer = Stream::SituationSnapshot.new(
      situation_id: "temp.anomaly", situation_version: 2,
      evidence: [{"kind" => "sliding_sum"}], uncertainty: 0.1,
      risk_class: :r1_notify, deadline: 1_700_000_060, created_at: 1_700_000_000
    )
    refute_equal one.snapshot_digest, newer.snapshot_digest
  end

  def test_admission_outcomes_admitted_debounced_coalesced_and_ignored
    # Fresh, in-window, under cost and confidence: admitted.
    assert_equal :admitted, Stream::CognitionAdmission.evaluate(
      trigger:, now: 1_700_000_010, spec: spec
    )

    # Debounce window: the same Situation was just debounced.
    assert_equal :debounced, Stream::CognitionAdmission.evaluate(
      trigger:, now: 1_700_000_010, debounced_at: 1_700_000_008, spec: spec
    )

    # Cooldown window: cognition was just admitted.
    assert_equal :coalesced, Stream::CognitionAdmission.evaluate(
      trigger:, now: 1_700_000_010, last_admitted_at: 1_700_000_009, spec: spec
    )

    # Stale evidence: ignored.
    assert_equal :ignored, Stream::CognitionAdmission.evaluate(
      trigger: trigger("freshness" => 31), now: 1_700_000_010, spec: spec
    )
  end

  def test_expiry_and_supersession_reject_across_the_adversarial_window
    # Expiry: the deadline passed before evaluation.
    assert_equal :expired, Stream::CognitionAdmission.evaluate(
      trigger: trigger("deadline" => 1_700_000_050), now: 1_700_000_055, spec: spec
    )

    # Supersession: a newer version already admitted — the late evaluation for
    # the OLD version is superseded (its snapshot is no longer current).
    assert_equal :superseded, Stream::CognitionAdmission.evaluate(
      trigger: trigger("situation_version" => 1),
      now: 1_700_000_010, current_version: 2, spec: spec
    )
    # Equal version is NOT superseded.
    assert_equal :admitted, Stream::CognitionAdmission.evaluate(
      trigger: trigger("situation_version" => 2),
      now: 1_700_000_010, current_version: 2, spec: spec
    )
  end

  def test_cost_and_confidence_ceilings_reject
    assert_equal :rejected, Stream::CognitionAdmission.evaluate(
      trigger: trigger("cost_estimate" => 101), now: 1_700_000_010, spec: spec
    )
    assert_equal :rejected, Stream::CognitionAdmission.evaluate(
      trigger: trigger("scores" => {"anomaly" => 0.95}), now: 1_700_000_010, spec: spec
    )
  end

  def test_bridge_namespace_and_request_id_are_deterministic_and_bounded
    namespace = Stream::CognitionAdmission.bridge_namespace("temp.anomaly")
    assert_equal %w[situation temp.anomaly], namespace

    request_id = Stream::CognitionAdmission.bridge_request_id(
      tenant_id: "tenant-1", situation_id: "temp.anomaly",
      situation_version: 1, admission_id: "adm.1"
    )
    again = Stream::CognitionAdmission.bridge_request_id(
      tenant_id: "tenant-1", situation_id: "temp.anomaly",
      situation_version: 1, admission_id: "adm.1"
    )
    assert_equal request_id, again
    assert_operator request_id.bytesize, :<=, 256,
                    "the derived request id must fit the Wire request-id bound"
  end
end
