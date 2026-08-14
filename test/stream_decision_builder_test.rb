# frozen_string_literal: true

require_relative "test_helper"
require "json_schemer"
require "tamoz/stream/episode_worker"
require "time"

# T2.4 (PLAN_TAMOZ_STREAM_BUILD T2.4): the typed Decision — decision-v1 shape,
# domain digest, wire-allowlisted action selection, and watch fallback.
class StreamDecisionBuilderTest < Minitest::Test
  Stream = Tamoz::Stream

  def worker
    Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def envelope
    envelope_with
  end

  def envelope_with(risk_ceiling: :RISK_CLASS_R2, allowed_intent_types: [
    "create_maintenance_ticket", "recommend_operating_limit"
  ], watch_confidence_floor: nil)
    request = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
      fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling:, allowed_intent_types:
    )
    request.watch_confidence_floor = watch_confidence_floor unless watch_confidence_floor.nil?
    Stream::EpisodeRequestEnvelope.new(request, worker)
  end

  def snapshot
    {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 1e-7}
    }
  end

  def build(outcome)
    Stream::DecisionBuilder.new(
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}", outcome:
    ).build
  end

  def test_a_confident_episode_proposes_a_consequential_intent
    decision, digest = build(
      primary_hypothesis: "bearing wear", confidence: 0.9,
      summary: "pressure trend", facts_used: [{"pressure" => 1e-7}]
    )

    assert_equal "decision.ep-1.at-1.1", decision.fetch("decision_id")
    assert_equal "sha256:#{"0" * 64}", decision.fetch("snapshot_digest")
    assert_equal 0.9, decision.fetch("confidence")
    assert_equal "bearing wear", decision.fetch("primary_hypothesis")

    intent = decision.fetch("intents").fetch(0)
    assert_equal "create_maintenance_ticket", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "c-01", intent.fetch("parameters").fetch("entity_id")

    # The decision digest verifies against the shared decision domain.
    assert Tamoz::Core.verify_digest(:decision, decision, digest)
    # Each intent carries its own digest over its content.
    intent_digest = intent.fetch("intent_digest")
    assert Tamoz::Core.verify_digest(
      :intent, intent.reject { |key, _| key == "intent_digest" }, intent_digest
    )
  end

  def test_a_low_confidence_episode_uses_an_allowlisted_action_when_watch_is_not_allowed
    decision, = build(
      primary_hypothesis: "possible drift", confidence: 0.3
    )

    intent = decision.fetch("intents").fetch(0)
    assert_equal "create_maintenance_ticket", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
  end

  def test_a_low_confidence_episode_prefers_an_allowlisted_watch_condition
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: ["create_maintenance_ticket", "install_watch_condition"],
        watch_confidence_floor: 0.5
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "possible drift", confidence: 0.3,
        watch_metric: "condition_score", watch_threshold: 0.8
      }
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type")
  end

  def test_a_high_confidence_episode_uses_the_action_when_watch_is_allowlisted
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: ["create_maintenance_ticket", "install_watch_condition"],
        watch_confidence_floor: 0.5
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "bearing wear", confidence: 0.9}
    ).build

    assert_equal "create_maintenance_ticket", decision.fetch("intents").fetch(0).fetch("type")
  end

  def test_a_zero_watch_floor_opts_out_of_watch_preference
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: ["create_maintenance_ticket", "install_watch_condition"],
        watch_confidence_floor: 0.0
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "possible drift", confidence: 0.3}
    ).build

    assert_equal "create_maintenance_ticket", decision.fetch("intents").fetch(0).fetch("type")
  end

  def test_a_watch_floor_does_not_force_a_watch_that_is_not_allowlisted
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: ["create_maintenance_ticket"],
        watch_confidence_floor: 0.5
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "possible drift", confidence: 0.3}
    ).build

    assert_equal "create_maintenance_ticket", decision.fetch("intents").fetch(0).fetch("type")
  end

  def test_an_uncertain_episode_uses_watch_when_no_action_is_allowlisted
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "possible drift", confidence: 0.3,
        watch_metric: "condition_score", watch_threshold: 0.8
      }
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type"),
                 "at low confidence the episode must observe when allowed"
    assert_equal "R0", intent.fetch("risk_class")
    assert_equal(
      "situation.condition_score >= 0.8",
      intent.fetch("parameters").fetch("expression")
    )
  end

  def test_confidence_is_clamped_to_the_unit_interval
    decision, = build(primary_hypothesis: "x", confidence: 1.7)
    assert_equal 1.0, decision.fetch("confidence")
  end

  def test_decision_validity_survives_stream_expiry_validation_after_build
    now = Time.utc(2026, 8, 13, 12)
    decision, = Stream::DecisionBuilder.new(
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "bearing wear", confidence: 0.9}, now:
    ).build

    valid_until = Time.iso8601(decision.fetch("valid_until"))
    validation_now = now + 1

    assert_equal now + 86_400, valid_until
    assert_operator valid_until, :>, now
    assert_operator valid_until, :>, validation_now,
                    "stream validation must not reject the decision as expired"
    assert_equal valid_until, Time.iso8601(decision.fetch("intents").first.fetch("expires_at"))
  end

  def test_a_r1_ceiling_excludes_the_r2_action
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(risk_ceiling: :RISK_CLASS_R1), snapshot:,
      snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "bearing wear", confidence: 0.9}
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "create_maintenance_ticket", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
  end

  def test_a_recommendation_is_proposed_when_it_is_the_only_allowlisted_action
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["recommend_operating_limit"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "bearing wear", confidence: 0.9}
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "recommend_operating_limit", intent.fetch("type")
    assert_equal "R2", intent.fetch("risk_class")
  end

  # F-1 (security review): a risk ceiling below the action's class, or an
  # allowlist without the action type, demotes the proposal to an
  # observation — the worker never escalates beyond what the runtime allowed.
  def test_a_low_risk_ceiling_never_proposes_a_consequential_action
    r0_envelope = Stream::EpisodeRequestEnvelope.new(
      Agenticstream::Runtime::V1::EpisodeRequest.new(
        protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
        fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
        kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
        risk_ceiling: :RISK_CLASS_R0,
        allowed_intent_types: ["install_watch_condition"]
      ),
      worker
    )
    decision, = Stream::DecisionBuilder.new(
      envelope: r0_envelope, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "seems bad", confidence: 0.9}
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type"),
                 "a confident episode under an R0 ceiling must still observe"
    assert_equal "R0", intent.fetch("risk_class")
  end

  def test_an_allowlist_without_the_action_type_demotes_the_proposal
    allowlist_envelope = Stream::EpisodeRequestEnvelope.new(
      Agenticstream::Runtime::V1::EpisodeRequest.new(
        protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
        fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
        kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
        risk_ceiling: :RISK_CLASS_R2,
        allowed_intent_types: ["install_watch_condition"]
      ),
      worker
    )
    decision, = Stream::DecisionBuilder.new(
      envelope: allowlist_envelope, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "seems bad", confidence: 0.9}
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type")
  end

  # F4 (coverage audit): the vendored decision-v1 schema is EXECUTED, not just
  # matched by shape — a schema drift fails the builder test.
  def test_the_decision_conforms_to_the_vendored_decision_v1_schema
    decision, = build(
      primary_hypothesis: "bearing wear", confidence: 0.9,
      summary: "pressure trend", facts_used: [{"pressure" => 1e-7}]
    )
    schema = JSONSchemer.schema(
      File.read(ROOT.join("gems/tamoz-stream/contracts/schemas/decision-v1.json"))
    )
    assert schema.valid?(decision),
           "the decision must conform to the vendored decision-v1 schema"
    intent_schema = JSONSchemer.schema(
      File.read(ROOT.join("gems/tamoz-stream/contracts/schemas/intent-v1.json"))
    )
    decision.fetch("intents").each do |intent|
      assert intent_schema.valid?(intent),
             "each intent must conform to the vendored intent-v1 schema"
    end
  end
end
