# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"

# P1/§"One real domain": the aquaculture DO-crash cell, re-authored as DATA —
# a diagnosis catalog, an operator prompt, an objective, snapshot facts, and
# (P4) an INTENT catalog with the domain's action vocabulary. The fixed
# episode graph is domain-agnostic; nothing here is hard-coded into any node
# (B9). Fixture responses are labeled `fixture` and are never shown as
# evidence of a real model path (B8).
module AquacultureDomain
  CATALOG = [
    {"code" => "unknown", "description" => "no confident diagnosis"},
    {"code" => "low_dissolved_oxygen", "description" => "dissolved oxygen below the safe threshold"},
    {"code" => "equipment_failure", "description" => "aerator or circulation equipment failed"},
    {"code" => "overstocking", "description" => "stocking density above the pond capacity"},
    {"code" => "feeding_overload", "description" => "feed input exceeding the oxygen budget"},
    {"code" => "temperature_stress", "description" => "water temperature outside the species range"}
  ].freeze

  OBJECTIVE = "Diagnose the cause of a dissolved-oxygen crash in one aquaculture pond and recommend the safest action."

  # P4: the domain's intent catalog — the SAME declared risks the deleted
  # ACTION_RISKS table held, re-authored as data (B9). The model proposes a
  # type; the decide node and Agentic Stream read the risk and the parameter
  # authority from HERE.
  INTENT_TYPES = {
    "install_watch_condition" => "R0",
    "create_maintenance_ticket" => "R1",
    "schedule_maintenance" => "R1",
    "reduce_load" => "R1",
    "downgrade_dispatch" => "R1",
    "withdraw_ticket" => "R1",
    "start_aerator" => "R1",
    "halt_feeding" => "R1",
    "downgrade_intervention" => "R1",
    "withdraw_intervention" => "R1",
    "run_vent_cycle" => "R1",
    "dehumidify" => "R1",
    "downgrade_climate_action" => "R1",
    "withdraw_climate_action" => "R1",
    "recommend_operating_limit" => "R2",
    "dispatch_crew" => "R2",
    "emergency_water_exchange" => "R2",
    "deploy_shade_or_heat" => "R2",
    "dose_co2" => "R2",
    "isolate_segment" => "R3"
  }.freeze

  WATCH_PRESET = {
    "expression" => "situation.condition_score >= 0.8",
    "metric" => "condition_score",
    "threshold" => 0.8,
    "max_fires" => 3
  }.freeze

  def self.intent_entry(type, risk)
    writable = type == "install_watch_condition" ? [] : %w[hypothesis]
    properties = {
      "entity_id" => {"type" => "string"},
      "situation_id" => {"type" => "string"},
      "situation_version" => {"type" => "integer"}
    }
    writable.each { |field| properties[field] = {"type" => "string", "maxLength" => 512} }
    if type == "install_watch_condition"
      WATCH_PRESET.each_key do |field|
        properties[field] = {"type" => %w[string number]} if %w[metric target expression].include?(field)
      end
      # The builder-bound watch keys are DECLARED so the schema the Go
      # validator enforces admits the parameters the builder actually emits.
      properties["target"] = {"type" => "string"}
      properties["expires_at"] = {"type" => "string"}
      properties["threshold"] = {"type" => "number"}
      properties["max_fires"] = {"type" => "integer"}
    end
    schema = {"type" => "object", "additionalProperties" => false, "properties" => properties}
    {
      "type" => type,
      "risk_class" => risk,
      "description" => "#{type} (#{risk})",
      "parameter_schema" => schema,
      "parameter_schema_digest" => "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(schema))}",
      "model_writable_fields" => writable,
      "presets" => type == "install_watch_condition" ? {"default" => WATCH_PRESET} : {"default" => {}},
      "policy" => {"requires_approval" => false},
      "rate_limit" => {"per_hour" => 60}
    }
  end

  INTENT_CATALOG = INTENT_TYPES.map { |type, risk| intent_entry(type, risk) }.freeze

  # The digest the wire carries: the shared domain rule over the FULL catalog
  # array (metadata included — a forged policy or rate limit must fail the
  # cross-boundary check).
  def self.intent_catalog_digest
    Tamoz::Core.digest(:intent_catalog, INTENT_CATALOG)
  end

  PROMPT = <<~TEXT.strip.freeze
    You are the pond supervisor's diagnostic assistant. The situation is a dissolved-oxygen
    crash in one aquaculture pond. Use ONLY the facts provided, reason about the most probable
    cause, and propose at most one action from the allowed list. Never invent facts. Never
    assign risk.

    OUTPUT STRICT JSON with EXACTLY this shape and no other text:
    {
      "protocol": "tamoz.episode-diagnosis/v2",
      "primary_hypothesis": "<one-sentence hypothesis>",
      "diagnosis_probabilities": [
        {"diagnosis_code": "<code>", "probability": <number>}
      ],
      "evidence_refs": ["fact:<id>"],
      "recommended_intents": [
        {"type": "<one type from the allowed action list>", "parameters": {"hypothesis": "<value>"}}
      ]
    }
    Rules: diagnosis_probabilities must cover EVERY code below exactly once;
    probabilities are numbers in [0,1] and sum to 1; evidence_refs cite only
    fact:<id> values from the user message. recommended_intents has at most one
    entry and its type must be one of the allowed actions; omit the entry to
    propose no action. Do not use markdown code fences — output the raw JSON
    object only.
  TEXT

  # Deterministic v2 documents for the fixture endpoint (gate 3: perturbed
  # response → different selected_code). Probabilities cover every catalog
  # code exactly once and sum to 1. The DO-crash domain proposes the aerator
  # action by default (P4: the model recommends; the catalog declares the
  # risk).
  def self.document(selected:, hypothesis:, intent: {type: "start_aerator", hypothesis: hypothesis})
    codes = CATALOG.map { |entry| entry.fetch("code") }
    total = codes.length.to_f
    probabilities = codes.map do |code|
      {
        "diagnosis_code" => code,
        "probability" => code == selected ? 0.8 : (0.2 / (total - 1)).round(4)
      }
    end
    # Fix rounding so the sum is exactly 1.0 within tolerance.
    probabilities.last["probability"] = (1.0 - probabilities[0..-2].sum { |p| p["probability"] }).round(4)
    document = {
      "protocol" => "tamoz.episode-diagnosis/v2",
      "primary_hypothesis" => hypothesis,
      "diagnosis_probabilities" => probabilities,
      "evidence_refs" => ["fact:dissolved_oxygen", "fact:pond_id"]
    }
    if intent
      document["recommended_intents"] = [
        {
          "type" => intent.fetch(:type),
          "parameters" => {"hypothesis" => String(intent.fetch(:hypothesis, hypothesis))}
        }
      ]
    end
    document
  end

  # Two fixture responses that must select different codes.
  FIXTURE_RESPONSES = [
    Tamoz::Core.jcs(document(selected: "low_dissolved_oxygen",
                              hypothesis: "dissolved oxygen is below the safe threshold")),
    Tamoz::Core.jcs(document(selected: "equipment_failure",
                              hypothesis: "the aerator stopped, driving oxygen down"))
  ].freeze

  def self.snapshot(pond_id: "pond-07", dissolved_oxygen: 1.2)
    {
      "situation_id" => "sit-do-crash",
      "situation_version" => 7,
      "tenant_id" => "acme",
      "situation_type" => "aquaculture",
      "entity" => {"type" => "pond", "id" => pond_id},
      "facts" => {
        "pond_id" => pond_id,
        "dissolved_oxygen" => dissolved_oxygen,
        "aerator_current" => 0.0,
        "water_temperature" => 26.5,
        "stocking_density" => 42.0,
        "hours_since_last_feeding" => 3.0,
        "surface_wind" => 2.0
      },
      "event_horizon" => "2026-08-15T00:00:00Z"
    }
  end

  # A profile document (hash) whose `fast` role points at the given endpoint.
  def self.profile_document(endpoint:, root:, model: "gemma4")
    {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "tamoz-worker-p1",
        "profile_version" => "1.0",
        "canonical_root" => root
      },
      "roots" => {"workspace" => root},
      "tools" => {"allowed" => %w[read_file list_directory], "approval_required" => []},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => "sha256:#{"0" * 64}"
      },
      "model_roles" => {
        "fast" => {
          "provider" => "ollama",
          "model" => model,
          "normalized_settings" => {"base_url" => endpoint}
        }
      }
    }
  end
end
