# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "support/aquaculture_domain"

# P4/§B9-B10: the spec-bound IntentCatalog — structural rules, the shared
# cross-boundary digest, and the fail-closed wire gate. Fixture data.
class AgentIntentCatalogTest < Minitest::Test
  Catalog = Tamoz::Agent::IntentCatalog

  def test_from_list_builds_the_catalog_with_declared_risks
    catalog = Catalog.from_list(AquacultureDomain::INTENT_CATALOG)

    assert_equal 22, catalog.types.length
    assert catalog.include?(Catalog::WATCH_TYPE)
    assert_equal "R0", catalog.risk_for("install_watch_condition")
    assert_equal "R1", catalog.risk_for("start_aerator")
    assert_equal "R3", catalog.risk_for("isolate_segment")
  end

  def test_verify_wire_accepts_the_honest_catalog
    catalog = Catalog.verify_wire(
      Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
      AquacultureDomain.intent_catalog_digest
    )
    assert_equal "R2", catalog.risk_for("recommend_operating_limit")
  end

  def test_verify_wire_rejects_a_forged_digest
    assert_raises(Tamoz::Agent::IntentCatalogError) do
      Catalog.verify_wire(
        Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
        "sha256:#{"0" * 64}"
      )
    end
  end

  def test_verify_wire_rejects_tampered_bytes_with_the_original_digest
    tampered = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "start_aerator" ? entry.merge("risk_class" => "R0") : entry
    end
    json = Tamoz::Core.jcs(tampered)
    # The wire still claims the ORIGINAL catalog's digest — the attack. The
    # bytes no longer match it, so the cross-boundary check refuses.
    assert_raises(Tamoz::Agent::IntentCatalogError) do
      Catalog.verify_wire(json, AquacultureDomain.intent_catalog_digest)
    end
  end

  def test_verify_wire_rejects_empty_and_missing_catalogs
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.verify_wire("", "sha256:#{"0" * 64}") }
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.verify_wire(nil, "sha256:#{"0" * 64}") }
  end

  def test_duplicate_types_are_refused
    entries = AquacultureDomain::INTENT_CATALOG + [AquacultureDomain::INTENT_CATALOG.first]
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_a_bad_risk_class_is_refused
    entries = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "start_aerator" ? entry.merge("risk_class" => "R9") : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_a_parameter_schema_that_is_not_an_object_is_refused
    entries = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "start_aerator" ? entry.merge("parameter_schema" => {"type" => "string"}) : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_model_writable_fields_must_be_in_the_schema
    entries = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "start_aerator" ? entry.merge("model_writable_fields" => ["ghost_field"]) : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_a_preset_with_unknown_parameters_is_refused
    entries = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "install_watch_condition" ?
        entry.merge("presets" => {"default" => {"ghost" => 1}}) : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_a_mismatched_schema_digest_is_refused
    entries = AquacultureDomain::INTENT_CATALOG.map do |entry|
      entry["type"] == "start_aerator" ?
        entry.merge("parameter_schema_digest" => "sha256:#{"1" * 64}") : entry
    end
    assert_raises(Tamoz::Agent::IntentCatalogError) { Catalog.from_list(entries) }
  end

  def test_order_binds_the_digest
    reversed = AquacultureDomain::INTENT_CATALOG.reverse
    catalog = Catalog.from_list(reversed)
    refute_equal Catalog.from_list(AquacultureDomain::INTENT_CATALOG).digest, catalog.digest,
                 "identical vocabularies in a different order digest differently"
  end

  def test_the_digest_round_trips_the_wire
    catalog = Catalog.from_list(AquacultureDomain::INTENT_CATALOG)
    # The digest over the parsed wire bytes equals the catalog's own digest.
    wire_digest = Tamoz::Core.digest(:intent_catalog, AquacultureDomain::INTENT_CATALOG)
    assert_equal catalog.digest, wire_digest
  end

  # P4/T5 cross-repo parity: this exact digest is pinned on the Go side
  # (internal/episodes/intent_catalog_test.go) — a drift on either side breaks
  # every Go-driven episode at this verify_wire gate.
  def test_the_aquaculture_catalog_digest_matches_the_pinned_cross_repo_vector
    assert_equal(
      "sha256:e4f866204344a5f19994e28afdea67b610e34405b062bbfd2879209a363d81f3",
      AquacultureDomain.intent_catalog_digest
    )
  end
end
