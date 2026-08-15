# frozen_string_literal: true

require_relative "test_helper"

# P7 (docs/new-design/PHASE_P7_BENCHMARK.md) — the benchmark protocol is the
# freeze. The gates protect it exactly like the requirements manifest:
#
# - it regenerates byte-identically from the authoritative sources, so no
#   field can drift from the code it describes;
# - the committed SHA-256 pin is asserted, so the file on disk is the frozen
#   artifact (a change to any field is a NEW benchmark version);
# - the structural invariants the phase doc names (11 stop rules, two
#   providers, the preregistered baselines, the min-case numbers) are checked
#   so a freeze cannot silently lose a clause.
class BenchmarkProtocolTest < Minitest::Test
  PROTOCOL_PATH = ROOT.join("docs", "benchmark", "BENCHMARK_PROTOCOL.json")

  # SHA-256 of the committed docs/benchmark/BENCHMARK_PROTOCOL.json. Bump only
  # when a protocol change is deliberate: this is the freeze.
  COMMITTED_SHA256 = "5e25b0b9de404ceb2f209da9f141f696e0a6f3215cdce6c9307a4f4cf0c66e4a"

  STOP_RULES = %w[
    truth_leak holdout_access fixture_or_fake_provider
    forged_or_missing_witness_record artifact_mismatch
    fabricated_evidence_reference cross_cell_memory hidden_domain_code
    silent_fallback accepted_risk_mismatch unreported_attempt
  ].freeze

  BASELINES = %w[
    majority_prior random_label fixed_threshold z_score first_difference
    moving_median nearest_symptom deterministic_detector go_native_executor
  ].freeze

  def protocol = @protocol ||= read_json(PROTOCOL_PATH)

  def test_protocol_regenerates_byte_identically
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, ROOT.join("script", "generate_benchmark_protocol").to_s,
      chdir: ROOT.to_s
    )

    assert status.success?, "the generator failed:\n#{stderr}#{stdout}"
    assert_equal File.binread(PROTOCOL_PATH), stdout,
                 "the committed protocol diverges from a fresh generation"
  end

  def test_committed_sha256_pin
    assert_equal COMMITTED_SHA256,
                 Digest::SHA256.hexdigest(File.binread(PROTOCOL_PATH))
  end

  def test_protocol_pins_the_build_and_graph
    assert_match(/\Asha256:[0-9a-f]{64}\z/, protocol.fetch("sealed_build_digest"))
    assert_equal "tamoz.agent.episode", protocol.dig("graph", "name")
    assert_match(/\A\d+\z/, protocol.dig("graph", "version").to_s)
  end

  def test_two_providers_including_a_pinned_local
    providers = protocol.fetch("providers")

    assert_equal 2, providers.size
    assert_equal %w[local-model pinned-local], providers.map { |p| p.fetch("identity") }
    assert_equal "tamoz-local-pinned", providers.last.fetch("provider")
  end

  def test_all_eleven_stop_rules_are_frozen
    assert_equal STOP_RULES, protocol.fetch("stop_rules")
  end

  def test_all_preregistered_baselines_are_frozen
    assert_equal BASELINES, protocol.fetch("baselines")
  end

  def test_freeze_fields_are_present
    assert_equal "1.0.0", protocol.fetch("benchmark_protocol_version")
    assert_equal %w[aquaculture climate], protocol.fetch("case_matrix").fetch("domains")
    assert_equal 30, protocol.dig("case_matrix", "min_cases_per_cell")
    assert_equal 30, protocol.dig("statistics", "min_cases_per_cell")
    assert_equal 0.05, protocol.dig("thresholds", "minimum_practical_effect")
    assert_equal 0.95, protocol.dig("thresholds", "confidence_interval")
    assert_equal "hard zero gate", protocol.dig("scoring", "evidence", "fabricated_reference_rate")
    assert_includes protocol.fetch("statistics").keys, "intention_to_treat"
    assert_includes protocol.fetch("statistics").keys, "paired_seeds_across_providers_and_baselines"
  end

  # Every scenario family freezes the detector baselines' metric + alarm code,
  # so the "strongest non-LLM baseline" sees each family's signal (a baseline
  # hardcoded to one family's metric would score half the corpus at zero).
  def test_every_scenario_family_freezes_its_metric_and_alarm
    protocol.fetch("case_matrix").fetch("scenario_families").each do |family|
      refute_empty family.fetch("metric"), "#{family.fetch("id")} must freeze its metric"
      refute_empty family.fetch("alarm_code"), "#{family.fetch("id")} must freeze its alarm code"
    end
    assert_equal "dissolved_oxygen", protocol.dig("case_matrix", "scenario_families", 0, "metric")
    assert_equal "zone_temperature", protocol.dig("case_matrix", "scenario_families", 1, "metric")
  end
end
