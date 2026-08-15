# frozen_string_literal: true

require_relative "test_helper"
require "json_schemer"
require "tamoz/stream/episode_worker"
require "support/aquaculture_domain"
require "time"

# T2.4 (PLAN_TAMOZ_STREAM_BUILD T2.4) + P4 (PHASE_P4_INTENT_AUTHORITY): the
# typed Decision — decision-v1 shape, domain digest, and catalog-driven intent
# selection. The model proposes; the catalog declares the risk, the parameter
# schema, the presets, and the model-writable fields (B9/B10). Fixture data
# throughout.
class StreamDecisionBuilderTest < Minitest::Test
  Stream = Tamoz::Stream
  Catalog = Tamoz::Agent::IntentCatalog

  def catalog
    @catalog ||= Catalog.from_list(AquacultureDomain::INTENT_CATALOG)
  end

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
      risk_ceiling:, allowed_intent_types:,
      intent_catalog_json: Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
      intent_catalog_sha256: AquacultureDomain.intent_catalog_digest
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
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome:, catalog:
    ).build
  end

  # The model's proposal, in the document-projection shape the builder reads.
  def proposal(type, parameters: nil, preset: nil)
    entry = {"type" => type}
    entry["parameter_preset"] = preset if preset
    entry["parameters"] = parameters if parameters
    entry
  end

  def test_a_proposal_for_an_allowlisted_action_uses_the_catalog_declared_risk
    decision, digest = build(
      primary_hypothesis: "bearing wear", confidence: 0.9,
      summary: "pressure trend", facts_used: [{"evidence" => "fact:p"}],
      evidence_ids: ["fact:p"],
      recommended_intents: [proposal("recommend_operating_limit", parameters: {"hypothesis" => "bearing wear"})]
    )

    assert_equal "decision.ep-1.at-1.1", decision.fetch("decision_id")
    assert_equal "sha256:#{"0" * 64}", decision.fetch("snapshot_digest")
    intent = decision.fetch("intents").fetch(0)
    assert_equal "recommend_operating_limit", intent.fetch("type")
    # The risk comes from the CATALOG, never the model (B10).
    assert_equal "R2", intent.fetch("risk_class")
    assert_equal catalog.risk_for("recommend_operating_limit"), intent.fetch("risk_class")
    # The intent grounds on the document's evidence refs.
    assert_equal ["fact:p"], intent.fetch("evidence_ids")
    # The builder binds the per-episode identity; the model's writable field
    # value rides along.
    parameters = intent.fetch("parameters")
    assert_equal "c-01", parameters.fetch("entity_id")
    assert_equal "bearing wear", parameters.fetch("hypothesis")

    # The decision digest verifies against the shared decision domain.
    assert Tamoz::Core.verify_digest(:decision, decision, digest)
    # Each intent carries its own digest over its content.
    intent_digest = intent.fetch("intent_digest")
    assert Tamoz::Core.verify_digest(
      :intent, intent.reject { |key, _| key == "intent_digest" }, intent_digest
    )
  end

  def test_no_proposal_degrades_to_the_catalog_watch_condition
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "possible drift", confidence: 0.3,
        evidence_ids: ["fact:drift"]
      },
      catalog:
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type")
    assert_equal "R0", intent.fetch("risk_class")
    assert_equal ["fact:drift"], intent.fetch("evidence_ids")
    # The watch parameters come from the catalog preset + per-episode bindings.
    parameters = intent.fetch("parameters")
    assert_equal "situation.condition_score >= 0.8", parameters.fetch("expression")
    assert_equal "c-01", parameters.fetch("entity_id")
  end

  def test_a_watch_fallback_without_an_allowlisted_watch_fails_closed
    # An episode whose allowlist leaves NO valid intent for the outcome must
    # not produce a decision Agentic Stream would reject (unallowlisted watch).
    error = assert_raises(Stream::StreamError) do
      Stream::DecisionBuilder.new(
        envelope: envelope_with(allowed_intent_types: ["start_aerator"]),
        snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {primary_hypothesis: "possible drift", confidence: 0.3},
        catalog:
      ).build
    end
    assert_match(/no allowed intent/, error.message)
  end

  def test_a_proposal_outside_the_allowlist_degrades_to_watch
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "seems bad", confidence: 0.9,
        recommended_intents: [proposal("start_aerator")]
      },
      catalog:
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type")
  end

  def test_a_proposal_outside_the_catalog_degrades_to_watch
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition", "start_aerator"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "seems bad", confidence: 0.9,
        recommended_intents: [proposal("launch_missiles")]
      },
      catalog:
    ).build

    assert_equal ["install_watch_condition"],
                 decision.fetch("intents").map { |intent| intent.fetch("type") }
  end

  def test_a_proposal_above_the_risk_ceiling_degrades_to_watch
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        risk_ceiling: :RISK_CLASS_R1,
        allowed_intent_types: ["install_watch_condition", "isolate_segment"]
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "ruptured main", confidence: 0.9,
        recommended_intents: [proposal("isolate_segment")]
      },
      catalog:
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "install_watch_condition", intent.fetch("type"),
                 "an R3 proposal under an R1 ceiling must observe, never escalate"
  end

  def test_a_model_value_for_a_non_writable_field_is_refused_typed
    assert_raises(Stream::StreamError) do
      Stream::DecisionBuilder.new(
        envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {
          primary_hypothesis: "bearing wear", confidence: 0.9,
          recommended_intents: [
            proposal("recommend_operating_limit", parameters: {"risk_ceiling" => "R0"})
          ]
        },
        catalog:
      ).build
    end
  end

  def test_two_actionable_intents_are_refused_typed
    error = assert_raises(Stream::StreamError) do
      Stream::DecisionBuilder.new(
        envelope: envelope_with(allowed_intent_types: %w[start_aerator halt_feeding]),
        snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {
          primary_hypothesis: "low oxygen", confidence: 0.9,
          recommended_intents: [
            proposal("start_aerator"), proposal("halt_feeding")
          ]
        },
        catalog:
      ).build
    end
    assert_match(/at most one actionable intent/, error.message)
  end

  def test_an_empty_allowlist_fails_closed
    error = assert_raises(Stream::StreamError) do
      Stream::DecisionBuilder.new(
        envelope: envelope_with(allowed_intent_types: []),
        snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {
          primary_hypothesis: "x", confidence: 0.9,
          recommended_intents: [proposal("recommend_operating_limit")]
        },
        catalog:
      ).build
    end
    assert_match(/must not be empty/, error.message)
  end

  def test_confidence_below_the_watch_floor_abstains
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: %w[start_aerator install_watch_condition],
        watch_confidence_floor: 0.5
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "low oxygen", confidence: 0.3,
        recommended_intents: [proposal("start_aerator")]
      },
      catalog:
    ).build

    assert_equal ["install_watch_condition"],
                 decision.fetch("intents").map { |intent| intent.fetch("type") },
                 "confidence below the floor abstains — it never unlocks an action"
  end

  def test_a_watch_only_outcome_proposes_only_the_watch_condition
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(
        allowed_intent_types: ["install_watch_condition"],
        watch_confidence_floor: 0.5
      ),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "possible drift", confidence: 0.3, watch_only: true
      },
      catalog:
    ).build

    assert_equal ["install_watch_condition"],
                 decision.fetch("intents").map { |intent| intent.fetch("type") }
  end

  def test_an_unknown_preset_is_refused_typed
    assert_raises(Stream::StreamError) do
      Stream::DecisionBuilder.new(
        envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {
          primary_hypothesis: "bearing wear", confidence: 0.9,
          recommended_intents: [proposal("recommend_operating_limit", preset: "nope")]
        },
        catalog:
      ).build
    end
  end

  def test_a_named_preset_fills_the_parameters
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition", "start_aerator"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "low oxygen", confidence: 0.9,
        recommended_intents: [proposal("start_aerator", preset: "default")]
      },
      catalog:
    ).build

    intent = decision.fetch("intents").fetch(0)
    assert_equal "start_aerator", intent.fetch("type")
    assert_equal "c-01", intent.fetch("parameters").fetch("entity_id")
  end

  def test_a_compensation_target_must_be_a_catalog_member
    # P6: the compensation mapping is part of the CATALOG's metadata — a
    # target that is not a catalog member is refused AT CATALOG LOAD (a
    # compensation can never bypass the catalog).
    tampered = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "create_maintenance_ticket" ?
        entry.merge("compensation" => {"withdraw" => "withdraw_ghost", "downgrade" => "downgrade_ghost"}) : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) do
      Catalog.from_list(tampered)
    end
  end

  def test_confidence_is_clamped_to_the_unit_interval
    decision, = build(
      primary_hypothesis: "x", confidence: 1.7,
      recommended_intents: [proposal("recommend_operating_limit")]
    )
    assert_equal 1.0, decision.fetch("confidence")
  end

  def test_a_watch_condition_parameters_satisfy_the_watch_effector_contract
    now = Time.utc(2026, 8, 14, 12)
    decision, = Stream::DecisionBuilder.new(
      envelope: envelope_with(allowed_intent_types: ["install_watch_condition"]),
      snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {primary_hypothesis: "possible drift", confidence: 0.3}, now:,
      catalog:
    ).build

    parameters = decision.fetch("intents").fetch(0).fetch("parameters")
    assert_equal "situation.condition_score >= 0.8", parameters.fetch("expression")
    assert_equal "c-01", parameters.fetch("target")
    assert_equal parameters.fetch("entity_id"), parameters.fetch("target")
    assert_equal "sit-1", parameters.fetch("situation_id")
    assert_equal 7, parameters.fetch("situation_version")
    assert_equal 3, parameters.fetch("max_fires")

    expires_at = Time.iso8601(parameters.fetch("expires_at"))
    assert_operator expires_at, :>, now
    assert_equal decision.fetch("valid_until"), parameters.fetch("expires_at")
  end

  def test_decision_validity_survives_stream_expiry_validation_after_build
    now = Time.utc(2026, 8, 13, 12)
    decision, = Stream::DecisionBuilder.new(
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {
        primary_hypothesis: "bearing wear", confidence: 0.9,
        recommended_intents: [proposal("recommend_operating_limit")]
      },
      now:, catalog:
    ).build

    valid_until = Time.iso8601(decision.fetch("valid_until"))
    validation_now = now + 1

    assert_equal now + 86_400, valid_until
    assert_operator valid_until, :>, now
    assert_operator valid_until, :>, validation_now,
                    "stream validation must not reject the decision as expired"
    assert_equal valid_until, Time.iso8601(decision.fetch("intents").first.fetch("expires_at"))
  end

  # F4 (coverage audit): the vendored decision-v1 schema is EXECUTED, not just
  # matched by shape — a schema drift fails the builder test.
  def test_the_decision_conforms_to_the_vendored_decision_v1_schema
    decision, = build(
      primary_hypothesis: "bearing wear", confidence: 0.9,
      summary: "pressure trend", facts_used: [{"evidence" => "fact:p"}],
      recommended_intents: [proposal("recommend_operating_limit", parameters: {"hypothesis" => "bearing wear"})]
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
