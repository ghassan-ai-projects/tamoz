# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"

# P4 exit gate 4: a NOVEL domain authored as DATA — diagnosis catalog, intent
# catalog, prompt, objective, snapshot, and fixture responses. ZERO production
# Ruby: the fixed graph is domain-agnostic (B9). The climate domain covers a
# greenhouse temperature/humidity cell.
module ClimateDomain
  CATALOG = [
    {"code" => "unknown", "description" => "no confident diagnosis"},
    {"code" => "overheated", "description" => "temperature above the species band"},
    {"code" => "overhumid", "description" => "relative humidity above the species band"},
    {"code" => "co2_depleted", "description" => "carbon dioxide below the enrichment band"},
    {"code" => "vent_failure", "description" => "vent actuator or fan failed"}
  ].freeze

  OBJECTIVE = "Diagnose the cause of a greenhouse climate deviation and recommend the safest action."

  INTENT_TYPES = {
    "install_watch_condition" => "R0",
    "run_vent_cycle" => "R1",
    "dehumidify" => "R1",
    "downgrade_climate_action" => "R1",
    "withdraw_climate_action" => "R1",
    "deploy_shade_or_heat" => "R2",
    "dose_co2" => "R2",
    "isolate_segment" => "R3",
    "open_roof_louvers" => "R1"
  }.freeze

  WATCH_PRESET = {
    "expression" => "situation.climate_score >= 0.8",
    "metric" => "climate_score",
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
      properties["metric"] = {"type" => "string"}
      properties["target"] = {"type" => "string"}
      properties["expression"] = {"type" => "string"}
      properties["expires_at"] = {"type" => "string"}
      properties["threshold"] = {"type" => "number"}
      properties["max_fires"] = {"type" => "integer"}
    end
    compensation_target = COMPENSATION_MAP.values.any? { |mapping| mapping.values.include?(type) }
    if compensation_target
      properties["note"] = {"type" => "string", "maxLength" => 512}
      properties["priority"] = {"type" => "string", "maxLength" => 16}
    end
    schema = {"type" => "object", "additionalProperties" => false, "properties" => properties}
    entry = {
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
    entry["compensation"] = COMPENSATION_MAP.fetch(type) if COMPENSATION_MAP.key?(type)
    entry
  end

  # P6: the climate compensation mapping — the compensating targets are
  # catalog members with their own declared risks.
  COMPENSATION_MAP = {
    "open_roof_louvers" => {"withdraw" => "withdraw_climate_action", "downgrade" => "downgrade_climate_action"},
    "run_vent_cycle" => {"withdraw" => "withdraw_climate_action", "downgrade" => "downgrade_climate_action"},
    "dehumidify" => {"withdraw" => "withdraw_climate_action", "downgrade" => "downgrade_climate_action"},
    "deploy_shade_or_heat" => {"withdraw" => "withdraw_climate_action", "downgrade" => "downgrade_climate_action"},
    "dose_co2" => {"withdraw" => "withdraw_climate_action", "downgrade" => "downgrade_climate_action"}
  }.freeze

  INTENT_CATALOG = INTENT_TYPES.map { |type, risk| intent_entry(type, risk) }.freeze

  def self.intent_catalog_digest
    Tamoz::Core.digest(:intent_catalog, INTENT_CATALOG)
  end

  PROMPT = <<~TEXT.strip.freeze
    You are the greenhouse supervisor's diagnostic assistant. Use ONLY the facts provided,
    diagnose the climate deviation, and propose at most one action from the allowed list.
    Never invent facts. Never assign risk.

    OUTPUT STRICT JSON with EXACTLY this shape and no other text:
    {
      "protocol": "tamoz.episode-diagnosis/v2",
      "primary_hypothesis": "<one-sentence hypothesis>",
      "diagnosis_probabilities": [{"diagnosis_code": "<code>", "probability": <number>}],
      "evidence_refs": ["fact:<id>"],
      "recommended_intents": [{"type": "<one type from the allowed action list>", "parameters": {"hypothesis": "<value>"}}]
    }
    Rules: probabilities cover EVERY code exactly once and sum to 1; evidence_refs cite only
    fact:<id> values; recommended_intents has at most one entry. No markdown code fences.
  TEXT

  def self.document(selected:, hypothesis:)
    codes = CATALOG.map { |entry| entry.fetch("code") }
    total = codes.length.to_f
    probabilities = codes.map do |code|
      {"diagnosis_code" => code, "probability" => code == selected ? 0.8 : (0.2 / (total - 1)).round(4)}
    end
    probabilities.last["probability"] = (1.0 - probabilities[0..-2].sum { |p| p["probability"] }).round(4)
    {
      "protocol" => "tamoz.episode-diagnosis/v2",
      "primary_hypothesis" => hypothesis,
      "diagnosis_probabilities" => probabilities,
      "evidence_refs" => ["fact:zone_temperature", "fact:zone_id"],
      "recommended_intents" => [
        {"type" => "run_vent_cycle", "parameters" => {"hypothesis" => hypothesis}}
      ]
    }
  end

  FIXTURE_RESPONSES = [
    Tamoz::Core.jcs(document(selected: "overheated", hypothesis: "the vent stuck closed, driving temperature up")),
    Tamoz::Core.jcs(document(selected: "overhumid", hypothesis: "condensation exceeded the dehumidifier capacity"))
  ].freeze

  def self.snapshot(zone_id: "zone-03", temperature: 33.5)
    {
      "situation_id" => "sit-climate",
      "situation_version" => 2,
      "tenant_id" => "acme",
      "situation_type" => "greenhouse",
      "entity" => {"type" => "greenhouse_zone", "id" => zone_id},
      "facts" => {
        "zone_id" => zone_id,
        "zone_temperature" => temperature,
        "zone_humidity" => 88.0,
        "zone_co2" => 280.0,
        "vent_open_fraction" => 0.0,
        "fan_current" => 0.0
      },
      "event_horizon" => "2026-08-15T00:00:00Z"
    }
  end
end
