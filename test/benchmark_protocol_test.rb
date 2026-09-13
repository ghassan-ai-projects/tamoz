# frozen_string_literal: true

require_relative "test_helper"

# The benchmark protocol in documentation/benchmark/ is the
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
  PROTOCOL_PATH = ROOT.join("documentation", "benchmark", "BENCHMARK_PROTOCOL.json")

  # SHA-256 of the committed documentation/benchmark/BENCHMARK_PROTOCOL.json. Bump only
  # when a protocol change is deliberate: this is the freeze. (2026-09-12 bump:
  # sealed_build_digest follows the Gemfile.lock change from the gem extractions
  # and the tamoz-agent-kernel net-http requirement tightening to ~> 0.5.
  # 2026-09-13 bump: Gemfile.lock gains faraday and base64 as declared deps.)
  COMMITTED_SHA256 = "d552e2777e2cf898620bdc99fa93677a6597d1aeb4b0e86b626c19eb8408bab0"

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
    assert_equal "1.1.0", protocol.fetch("benchmark_protocol_version")
    assert_equal %w[aquaculture climate], protocol.fetch("case_matrix").fetch("domains")
    assert_equal 30, protocol.dig("case_matrix", "min_cases_per_cell")
    assert_equal 30, protocol.dig("statistics", "min_cases_per_cell")
    assert_equal 0.05, protocol.dig("thresholds", "minimum_practical_effect")
    assert_equal 0.95, protocol.dig("thresholds", "confidence_interval")
    assert_equal "hard zero gate", protocol.dig("scoring", "evidence", "fabricated_reference_rate")
    assert_includes protocol.fetch("statistics").keys, "intention_to_treat"
    assert_includes protocol.fetch("statistics").keys, "paired_seeds_across_providers_and_baselines"
    # The baselines' seeds are data, not gem-code defaults (domain-leak fix):
    # random_label draws from random_label_seed, the paired comparison from
    # bootstrap_seed.
    assert_equal 1, protocol.dig("statistics", "random_label_seed")
    assert_equal 7, protocol.dig("statistics", "bootstrap_seed")
  end

  # Every scenario family freezes the detector baselines' metric + alarm code,
  # so the "strongest non-LLM baseline" sees each family's signal (a baseline
  # hardcoded to one family's metric would score half the corpus at zero).
  # v1.1: the truth threshold + operator are frozen per family too — the
  # fixed_threshold detector reads them (no defaults), and the operator keeps
  # the gt family (climate) from being evaluated lt-side.
  def test_every_scenario_family_freezes_its_metric_and_alarm
    protocol.fetch("case_matrix").fetch("scenario_families").each do |family|
      refute_empty family.fetch("metric"), "#{family.fetch("id")} must freeze its metric"
      refute_empty family.fetch("alarm_code"), "#{family.fetch("id")} must freeze its alarm code"
      assert family.key?("threshold"), "#{family.fetch("id")} must freeze its threshold"
      assert_includes %w[lt gt], family.fetch("operator"), "#{family.fetch("id")} must freeze lt/gt"
    end
    assert_equal "dissolved_oxygen", protocol.dig("case_matrix", "scenario_families", 0, "metric")
    assert_equal "zone_temperature", protocol.dig("case_matrix", "scenario_families", 1, "metric")
    assert_equal 2.0, protocol.dig("case_matrix", "scenario_families", 0, "threshold")
    assert_equal "lt", protocol.dig("case_matrix", "scenario_families", 0, "operator")
    assert_equal 31.0, protocol.dig("case_matrix", "scenario_families", 1, "threshold")
    assert_equal "gt", protocol.dig("case_matrix", "scenario_families", 1, "operator")
  end

  # Domain-knowledge extraction: the domain data must bind the SAME wire
  # digests the protocol freezes — all six (two intent catalogs, two
  # diagnosis catalogs, two prompts) recomputed through the JSON loader.
  # This closes the climate-diagnosis gap (the protocol only pins the
  # aquaculture diagnosis digest) and guards lockstep drift.
  def test_domain_data_binds_the_frozen_wire_digests
    require "support/domain_loader"
    loader = DomainLoader.load("aquaculture")
    assert_equal protocol.dig("digests", "intent_catalog_aquaculture"),
                 loader.intent_catalog_digest
    assert_equal protocol.dig("digests", "diagnosis_catalog"),
                 Tamoz::Core.digest(:diagnosis_catalog, loader.catalog)
    assert_equal protocol.dig("digests", "prompt_aquaculture"),
                 Tamoz::Core.digest("situation-runtime/prompt/v1\n",
                                    {"version" => "1.0", "text" => loader.prompt})

    climate = DomainLoader.load("climate")
    assert_equal protocol.dig("digests", "intent_catalog_climate"),
                 climate.intent_catalog_digest
    assert_equal "sha256:bb2b4789e3b75628c888daffb6c27426230d3d0c7861198a0489d5d71eb18d58",
                 Tamoz::Core.digest(:diagnosis_catalog, climate.catalog)
    assert_equal protocol.dig("digests", "prompt_climate"),
                 Tamoz::Core.digest("situation-runtime/prompt/v1\n",
                                    {"version" => "1.0", "text" => climate.prompt})
  end

  # The protocol's per-family metric/alarm (what the Report scores against)
  # must agree with the domain data's benchmark_family config (what the
  # holdout/pilot generate series under) — one drift window closed. v1.1 also
  # binds the truth threshold + operator the fixed_threshold detector reads.
  def test_family_config_agrees_between_protocol_and_domain_data
    require "support/domain_loader"
    protocol.fetch("case_matrix").fetch("scenario_families").each do |family|
      config = DomainLoader.load(family.fetch("domain")).benchmark_family
      assert_equal family.fetch("metric"), config.fetch("metric"),
                   "family #{family.fetch("id")} metric must agree"
      assert_equal family.fetch("alarm_code"), config.fetch("alarm_code"),
                   "family #{family.fetch("id")} alarm_code must agree"
      assert_equal family.fetch("threshold"), config.dig("truth", "threshold"),
                   "family #{family.fetch("id")} threshold must agree"
      assert_equal family.fetch("operator"), config.dig("truth", "operator"),
                   "family #{family.fetch("id")} operator must agree"
    end
  end
end
