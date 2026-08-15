# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"

# P1/§"One real domain": the aquaculture DO-crash cell, re-authored as DATA —
# a diagnosis catalog, an operator prompt, an objective, and snapshot facts.
# The fixed episode graph is domain-agnostic; nothing here is hard-coded into
# any node (B9). Fixture responses are labeled `fixture` and are never shown
# as evidence of a real model path (B8).
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
      "evidence_refs": ["fact:<id>"]
    }
    Rules: diagnosis_probabilities must cover EVERY code below exactly once;
    probabilities are numbers in [0,1] and sum to 1; evidence_refs cite only
    fact:<id> values from the user message. Do not use markdown code fences —
    output the raw JSON object only.
  TEXT

  # Deterministic v2 documents for the fixture endpoint (gate 3: perturbed
  # response → different selected_code). Probabilities cover every catalog
  # code exactly once and sum to 1.
  def self.document(selected:, hypothesis:)
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
    {
      "protocol" => "tamoz.episode-diagnosis/v2",
      "primary_hypothesis" => hypothesis,
      "diagnosis_probabilities" => probabilities,
      "evidence_refs" => ["fact:dissolved_oxygen", "fact:pond_id"]
    }
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
