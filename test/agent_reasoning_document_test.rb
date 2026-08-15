# frozen_string_literal: true

require_relative "test_helper"

# P0B/§5 conformance: the strict ReasoningDocument v2 parser accepts a
# well-formed turn and fails closed on every malformed, forged, or
# authority-smuggling variant. Each rejection asserts the stable
# `reasoning_document/<code>` prefix so the contract cannot silently drift.
class AgentReasoningDocumentTest < Minitest::Test
  Doc = Tamoz::Agent::ReasoningDocument
  CATALOG = %w[ventilation_failure sensor_drift unknown].freeze

  def terminal_hash
    {
      "protocol" => Doc::PROTOCOL,
      "primary_hypothesis" => "vent motor stalled overnight",
      "diagnosis_probabilities" => [
        {"diagnosis_code" => "ventilation_failure", "probability" => 0.72},
        {"diagnosis_code" => "sensor_drift", "probability" => 0.18},
        {"diagnosis_code" => "unknown", "probability" => 0.10}
      ],
      "evidence_refs" => ["fact:/facts/pressure"],
      "recommended_intents" => [{"type" => "create_maintenance_ticket", "parameter_preset" => "conservative"}]
    }
  end

  def tool_hash
    {
      "protocol" => Doc::PROTOCOL,
      "tool_requests" => [{"name" => "evidence_get", "arguments" => {"metric" => "pressure"}}]
    }
  end

  def parse(hash) = Doc.parse(JSON.generate(hash), catalog: CATALOG)

  def assert_rejected(code, hash_or_string)
    bytes = hash_or_string.is_a?(String) ? hash_or_string : JSON.generate(hash_or_string)
    error = assert_raises(Tamoz::Agent::ProtocolError) { Doc.parse(bytes, catalog: CATALOG) }
    assert_includes error.message, "reasoning_document/#{code}", "expected rejection code #{code}"
  end

  # --- happy paths ---

  def test_parses_terminal_turn_and_derives_selection
    doc = parse(terminal_hash)
    assert doc.terminal?
    assert_equal "ventilation_failure", doc.selected_code
    assert_in_delta 0.72, doc.raw_confidence, 1e-9
    assert_equal 1, doc.recommended_intents.length
    assert_equal ["fact:/facts/pressure"], doc.evidence_refs
    assert_nil doc.tool_requests
  end

  def test_argmax_tie_breaks_on_catalog_order
    hash = terminal_hash
    hash["diagnosis_probabilities"] = [
      {"diagnosis_code" => "ventilation_failure", "probability" => 0.5},
      {"diagnosis_code" => "sensor_drift", "probability" => 0.5},
      {"diagnosis_code" => "unknown", "probability" => 0.0}
    ]
    # Equal top probability: the earlier catalog entry wins deterministically.
    assert_equal "ventilation_failure", parse(hash).selected_code
  end

  def test_parses_tool_turn
    doc = parse(tool_hash)
    assert doc.tool_turn?
    assert_equal "evidence_get", doc.tool_requests.first.name
    assert_nil doc.probabilities
    assert_nil doc.selected_code
  end

  def test_evidence_refs_optional_defaults_empty
    hash = terminal_hash
    hash.delete("evidence_refs")
    assert_equal [], parse(hash).evidence_refs
  end

  # --- structural rejections ---

  def test_rejects_prose_wrapped_json
    assert_rejected("malformed_json", "Here is the decision: #{JSON.generate(terminal_hash)}")
  end

  def test_rejects_non_object_root
    assert_rejected("not_object", JSON.generate([1, 2, 3]))
  end

  def test_rejects_duplicate_top_level_key
    raw = %({"protocol":"#{Doc::PROTOCOL}","protocol":"#{Doc::PROTOCOL}"})
    assert_rejected("duplicate_key", raw)
  end

  def test_rejects_unknown_top_level_key
    assert_rejected("unknown_key", terminal_hash.merge("confidence" => 0.9))
  end

  def test_rejects_model_asserted_selected_diagnosis
    # The model must not assert the selected code; it is a Tamoz derivation.
    assert_rejected("unknown_key", terminal_hash.merge("selected_diagnosis" => "unknown"))
  end

  def test_rejects_wrong_protocol
    assert_rejected("protocol", terminal_hash.merge("protocol" => "tamoz.episode-diagnosis/v1"))
  end

  def test_rejects_invalid_utf8
    assert_rejected("invalid_utf8", (+"\xff\xfe").force_encoding(Encoding::UTF_8))
  end

  def test_rejects_oversize_document
    hash = terminal_hash
    hash["primary_hypothesis"] = "x" * (Doc::MAX_BYTES + 10)
    assert_rejected("document_too_large", hash)
  end

  # --- terminal-turn semantics ---

  def test_rejects_missing_catalog_code
    hash = terminal_hash
    hash["diagnosis_probabilities"] = hash["diagnosis_probabilities"].reject { |p| p["diagnosis_code"] == "unknown" }
    assert_rejected("missing_diagnosis_codes", hash)
  end

  def test_rejects_unknown_diagnosis_code
    hash = terminal_hash
    hash["diagnosis_probabilities"][0]["diagnosis_code"] = "not_in_catalog"
    assert_rejected("unknown_diagnosis_code", hash)
  end

  def test_rejects_duplicate_diagnosis_code
    hash = terminal_hash
    # Same entry count as the catalog, but "unknown" twice and sensor_drift absent.
    hash["diagnosis_probabilities"] = [
      {"diagnosis_code" => "ventilation_failure", "probability" => 0.5},
      {"diagnosis_code" => "unknown", "probability" => 0.25},
      {"diagnosis_code" => "unknown", "probability" => 0.25}
    ]
    assert_rejected("duplicate_diagnosis_code", hash)
  end

  def test_rejects_probabilities_not_summing_to_one
    hash = terminal_hash
    hash["diagnosis_probabilities"][0]["probability"] = 0.9
    assert_rejected("probabilities_sum", hash)
  end

  def test_rejects_non_finite_probability
    raw = JSON.generate(terminal_hash).sub("0.72", "1e400")
    assert_rejected("probability_not_finite", raw)
  end

  def test_rejects_out_of_range_probability
    hash = terminal_hash
    hash["diagnosis_probabilities"][0]["probability"] = 1.5
    assert_rejected("probability_range", hash)
  end

  def test_rejects_non_numeric_probability
    hash = terminal_hash
    hash["diagnosis_probabilities"][0]["probability"] = "0.72"
    assert_rejected("probability_not_number", hash)
  end

  # --- evidence-ref and intent rejections ---

  def test_rejects_malformed_evidence_ref
    hash = terminal_hash
    hash["evidence_refs"] = ["pressure"]
    assert_rejected("evidence_ref_format", hash)
  end

  def test_rejects_intent_with_preset_and_parameters
    hash = terminal_hash
    hash["recommended_intents"] = [{"type" => "t", "parameter_preset" => "p", "parameters" => {"a" => 1}}]
    assert_rejected("intent_preset_and_parameters", hash)
  end

  # --- tool/terminal mutual exclusion ---

  def test_rejects_tool_turn_with_terminal_field
    hash = tool_hash.merge("primary_hypothesis" => "leak")
    assert_rejected("tool_turn_has_terminal_field", hash)
  end

  def test_rejects_empty_tool_requests
    assert_rejected("empty_tool_requests", {"protocol" => Doc::PROTOCOL, "tool_requests" => []})
  end

  # --- catalog guards ---

  def test_rejects_empty_catalog
    error = assert_raises(Tamoz::Agent::ProtocolError) { Doc.parse(JSON.generate(terminal_hash), catalog: []) }
    assert_includes error.message, "reasoning_document/catalog_empty"
  end
end
