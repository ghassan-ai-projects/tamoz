# frozen_string_literal: true

require_relative "test_helper"

# P0B/§5 conformance: the diagnosis catalog is trusted spec config with an
# order-binding, domain-separated digest, and fails closed on malformed input.
class AgentDiagnosisCatalogTest < Minitest::Test
  Catalog = Tamoz::Agent::DiagnosisCatalog

  def list
    [
      {code: "ventilation_failure", description: "vent motor stalled"},
      {code: "sensor_drift", description: "probe reading drift"},
      {code: "unknown", description: "no confident diagnosis"}
    ]
  end

  def assert_rejected(code, list)
    error = assert_raises(Tamoz::Agent::DiagnosisCatalogError) { Catalog.from_list(list) }
    assert_includes error.message, "diagnosis_catalog/#{code}"
  end

  def test_builds_and_preserves_order
    catalog = Catalog.from_list(list)
    assert_equal %w[ventilation_failure sensor_drift unknown], catalog.codes
    assert catalog.include?("sensor_drift")
    assert_equal "vent motor stalled", catalog.description("ventilation_failure")
  end

  def test_digest_is_domain_separated_and_stable
    a = Catalog.from_list(list).digest
    b = Catalog.from_list(list).digest
    assert_match(/\Asha256:[0-9a-f]{64}\z/, a)
    assert_equal a, b
  end

  def test_digest_binds_order
    reordered = [list[1], list[0], list[2]]
    refute_equal Catalog.from_list(list).digest, Catalog.from_list(reordered).digest
  end

  def test_digest_changes_with_description
    edited = list.map(&:dup)
    edited[0] = {code: "ventilation_failure", description: "changed"}
    refute_equal Catalog.from_list(list).digest, Catalog.from_list(edited).digest
  end

  def test_rejects_missing_unknown
    assert_rejected("missing_unknown", list.reject { |e| e[:code] == "unknown" })
  end

  def test_rejects_duplicate_code
    assert_rejected("duplicate_code", list + [{code: "unknown", description: "dup"}])
  end

  def test_rejects_malformed_code
    ["Ventilation", "vent failure", "1bad", "vent-failure", ""].each do |bad|
      assert_rejected("bad_code", [{code: bad, description: "x"}, {code: "unknown", description: "y"}])
    end
  end

  def test_rejects_empty_and_non_array
    assert_rejected("empty", [])
    assert_rejected("not_array", {})
  end

  def test_rejects_oversized_description
    big = [{code: "ventilation_failure", description: "x" * (Catalog::MAX_DESCRIPTION_BYTES + 1)},
           {code: "unknown", description: "y"}]
    assert_rejected("description_too_large", big)
  end

  def test_reasoning_document_accepts_catalog_instance
    catalog = Catalog.from_list(list)
    hash = {
      "protocol" => Tamoz::Agent::ReasoningDocument::PROTOCOL,
      "primary_hypothesis" => "vent stalled",
      "diagnosis_probabilities" => [
        {"diagnosis_code" => "ventilation_failure", "probability" => 0.7},
        {"diagnosis_code" => "sensor_drift", "probability" => 0.2},
        {"diagnosis_code" => "unknown", "probability" => 0.1}
      ]
    }
    doc = Tamoz::Agent::ReasoningDocument.parse(JSON.generate(hash), catalog: catalog)
    assert_equal "ventilation_failure", doc.selected_code
  end

  # --- wire verification (fails closed before a model call) ---

  def wire_json
    JSON.generate([
      {"code" => "ventilation_failure", "description" => "vent motor stalled"},
      {"code" => "sensor_drift", "description" => "probe reading drift"},
      {"code" => "unknown", "description" => "no confident diagnosis"}
    ])
  end

  def wire_digest(json = wire_json)
    Tamoz::Core.digest(:diagnosis_catalog, Tamoz::Core.parse_json_strict(json))
  end

  def test_verify_wire_accepts_matching_digest
    catalog = Catalog.verify_wire(wire_json, wire_digest)
    assert_equal %w[ventilation_failure sensor_drift unknown], catalog.codes
    # The value object recomputes the identical cross-boundary digest.
    assert_equal wire_digest, catalog.digest
  end

  def test_verify_wire_rejects_forged_digest
    error = assert_raises(Tamoz::Agent::DiagnosisCatalogError) { Catalog.verify_wire(wire_json, "sha256:#{"0" * 64}") }
    assert_includes error.message, "digest_mismatch"
  end

  def test_verify_wire_rejects_tampered_bytes
    tampered = wire_json.sub("vent motor stalled", "vent motor STALLED")
    error = assert_raises(Tamoz::Agent::DiagnosisCatalogError) { Catalog.verify_wire(tampered, wire_digest) }
    assert_includes error.message, "digest_mismatch"
  end

  def test_verify_wire_rejects_empty
    error = assert_raises(Tamoz::Agent::DiagnosisCatalogError) { Catalog.verify_wire("", wire_digest) }
    assert_includes error.message, "wire_empty"
  end

  def test_rejects_unknown_entry_key
    assert_rejected("unknown_entry_key", [{code: "unknown", description: "x", sealed_truth: "vent"}])
  end
end
