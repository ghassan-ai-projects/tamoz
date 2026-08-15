# frozen_string_literal: true

require_relative "test_helper"

# P7 (docs/new-design/PHASE_P7_BENCHMARK.md): the frozen metric functions, the
# preregistered baselines, and the paired comparison. Pure + deterministic —
# the same cells re-scored anywhere yield the same numbers (offline
# reproducibility is a go-rule input). These tests pin the DEFINITIONS, not a
# specific run: a metric that stops measuring what the protocol names is a
# new benchmark version, so its behavior is frozen here.
class BenchmarkHarnessTest < Minitest::Test
  CODES = %w[low_dissolved_oxygen equipment_failure unknown].freeze

  def cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen", probabilities: nil, scenario_family: "do-crash",
           evidence_refs: ["fact:dissolved_oxygen"], valid_evidence_ids: ["fact:dissolved_oxygen"],
           first_observable_at: "2026-08-15T00:00:00Z", decision_at: "2026-08-15T00:05:00Z",
           gold_risk_class: nil, intent_risk_classes: [], facts: {"dissolved_oxygen" => 1.2},
           tokens: 0, tool_bytes: 0, cell_id: nil, label: nil)
    {
      "cell_id" => cell_id || "cell-#{rand(10_000)}",
      "label" => label,
      "scenario_family" => scenario_family,
      "primary_code" => primary,
      "truth_code" => truth,
      "probabilities" => probabilities || {"low_dissolved_oxygen" => 0.8, "equipment_failure" => 0.1, "unknown" => 0.1},
      "evidence_refs" => evidence_refs,
      "valid_evidence_ids" => valid_evidence_ids,
      "first_observable_at" => first_observable_at,
      "decision_at" => decision_at,
      "gold_risk_class" => gold_risk_class,
      "intent_risk_classes" => intent_risk_classes,
      "facts" => facts,
      "tokens" => tokens,
      "tool_bytes" => tool_bytes
    }
  end

  def metrics
    Tamoz::Evals::Benchmark::Metrics
  end

  def test_macro_f1_is_one_for_a_perfect_classifier
    cells = [
      cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen"),
      cell(primary: "equipment_failure", truth: "equipment_failure"),
      cell(primary: "unknown", truth: "unknown")
    ]
    assert_in_delta 1.0, metrics.macro_f1(cells, CODES), 1e-9
  end

  def test_macro_f1_collapses_to_zero_for_a_wrong_classifier
    cells = [
      cell(primary: "equipment_failure", truth: "low_dissolved_oxygen"),
      cell(primary: "unknown", truth: "equipment_failure"),
      cell(primary: "low_dissolved_oxygen", truth: "unknown")
    ]
    assert_in_delta 0.0, metrics.macro_f1(cells, CODES), 1e-9
  end

  def test_macro_f1_averages_across_codes_not_cells
    # 10 correct + 10 wrong on the same code is NOT ~0.5 macro-F1: the code
    # the model is right about carries precision 1 but recall 0.5 (10 of 20
    # true low_dissolved_oxygen cells were caught), so F1 = 0.667; the other
    # codes carry 0. The average is over CODES, not cells.
    cells = 10.times.map { cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen") } +
            10.times.map { cell(primary: "equipment_failure", truth: "low_dissolved_oxygen") }
    assert_in_delta (0.667 + 0.0 + 0.0) / 3, metrics.macro_f1(cells, CODES), 1e-3
  end

  def test_balanced_accuracy_is_mean_recall_over_codes
    cells = [
      cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen"),
      cell(primary: "unknown", truth: "low_dissolved_oxygen"),
      cell(primary: "equipment_failure", truth: "equipment_failure")
    ]
    # low_dissolved_oxygen: recall 0.5; equipment_failure: recall 1; unknown: undefined 0
    assert_in_delta (0.5 + 1.0 + 0.0) / 3, metrics.balanced_accuracy(cells, CODES), 1e-9
  end

  def test_brier_penalizes_overconfidence_on_wrong_codes
    confident = [cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
                      probabilities: {"low_dissolved_oxygen" => 1.0, "equipment_failure" => 0.0, "unknown" => 0.0})]
    spread = [cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
                   probabilities: {"low_dissolved_oxygen" => 0.6, "equipment_failure" => 0.2, "unknown" => 0.2})]
    # (1-1)^2*... = 0 vs (0.4^2 + 0.2^2 + 0.2^2)/3
    assert_in_delta 0.0, metrics.brier(confident, CODES), 1e-9
    assert_in_delta (0.16 + 0.04 + 0.04) / 3, metrics.brier(spread, CODES), 1e-9
  end

  def test_log_loss_penalizes_a_zero_probability_on_the_truth
    cells = [cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
                  probabilities: {"low_dissolved_oxygen" => 1.0, "equipment_failure" => 0.0, "unknown" => 0.0})]
    assert_in_delta 0.0, metrics.log_loss(cells, CODES), 1e-9

    # The penalty is real: a probability pinned at the floor on the truth code
    # costs -ln(floor) ≈ 20.7, not the perfect-case 0.
    confident_wrong = [cell(primary: "equipment_failure", truth: "low_dissolved_oxygen",
                            probabilities: {"low_dissolved_oxygen" => 1e-12,
                                            "equipment_failure" => 1.0 - 1e-12, "unknown" => 0.0})]
    assert_operator metrics.log_loss(confident_wrong, CODES), :>, 20.0,
                    "a near-zero probability on the truth code must cost the floor"
  end

  def test_calibration_is_zero_for_a_perfectly_calibrated_classifier
    # All cells confident at 1.0 and all correct: the single occupied bin has
    # mean confidence 1.0 and accuracy 1.0 — ECE 0.
    cells = 10.times.map do
      cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
           probabilities: {"low_dissolved_oxygen" => 1.0, "equipment_failure" => 0.0, "unknown" => 0.0})
    end
    assert_in_delta 0.0, metrics.calibration(cells, CODES), 1e-6
  end

  def test_calibration_is_one_for_confident_and_wrong
    # All cells confident at 1.0 and all wrong: mean confidence 1.0, accuracy
    # 0 — ECE 1.
    cells = 10.times.map do
      cell(primary: "low_dissolved_oxygen", truth: "equipment_failure",
           probabilities: {"low_dissolved_oxygen" => 1.0, "equipment_failure" => 0.0, "unknown" => 0.0})
    end
    assert_in_delta 1.0, metrics.calibration(cells, CODES), 1e-6
  end

  def test_risk_coverage_drops_with_confidence_threshold
    cells = [
      cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
           probabilities: {"low_dissolved_oxygen" => 0.95, "equipment_failure" => 0.03, "unknown" => 0.02}),
      cell(primary: "equipment_failure", truth: "low_dissolved_oxygen",
           probabilities: {"low_dissolved_oxygen" => 0.55, "equipment_failure" => 0.40, "unknown" => 0.05})
    ]
    curve = metrics.risk_coverage(cells, CODES)
    low = curve.first
    high = curve.last
    assert_operator low.fetch("coverage"), :>=, high.fetch("coverage")
  end

  def test_fabricated_reference_rate_counts_refs_outside_the_frame
    clean = [cell(evidence_refs: ["fact:dissolved_oxygen"])]
    forged = [cell(evidence_refs: ["fact:dissolved_oxygen", "fact:made_up"])]
    assert_in_delta 0.0, metrics.fabricated_reference_rate(clean), 1e-9
    assert_in_delta 1.0, metrics.fabricated_reference_rate(forged), 1e-9
  end

  def test_lead_time_is_decision_minus_first_observable
    cells = [cell(first_observable_at: "2026-08-15T00:00:00Z", decision_at: "2026-08-15T00:05:30Z")]
    assert_in_delta 330.0, metrics.lead_time(cells), 1e-9
  end

  def test_action_utility_counts_missed_catastrophes_and_false_actions_separately
    missed = [
      cell(gold_risk_class: "R2", intent_risk_classes: ["R1"]),
      cell(gold_risk_class: "R3", intent_risk_classes: []),
      cell(gold_risk_class: "R2", intent_risk_classes: ["R2"]),
      cell(gold_risk_class: nil, intent_risk_classes: ["R1"])
    ]
    utility = metrics.action_utility(missed, missed_cost: 100.0, false_cost: 1.0)
    assert_equal 2, utility.fetch("missed_catastrophes")
    assert_equal 1, utility.fetch("false_actions")
    assert_in_delta 200.0, utility.fetch("missed_catastrophe_cost"), 1e-9
    assert_in_delta 1.0, utility.fetch("false_action_cost"), 1e-9
  end

  def test_cost_per_cell_sums_tokens_and_tool_bytes
    cells = [cell(tokens: 100, tool_bytes: 20), cell(tokens: 50, tool_bytes: 30)]
    cost = metrics.cost_per_cell(cells)
    assert_equal 150, cost.fetch("provider_tokens")
    assert_equal 50, cost.fetch("tool_bytes")
    assert_in_delta 100.0, cost.fetch("per_cell_mean"), 1e-9
  end

  def test_sparse_probabilities_are_completed_and_renormalized
    cells = [cell(primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
                  probabilities: {"low_dissolved_oxygen" => 0.9})]
    # The missing codes must not vanish from the vector — they are completed
    # to 0 and the vector renormalized to a distribution, so the metric math
    # always sees a valid probability vector (brier/log-loss sum over ALL
    # codes). {0.9, 0, 0} renormalized is {1.0, 0, 0}.
    assert_in_delta 0.0, metrics.brier(cells, CODES), 1e-9
    assert_in_delta 0.0, metrics.log_loss(cells, CODES), 1e-9
  end

  def test_baselines_are_deterministic
    cells = 6.times.map { |index| cell(primary: "unknown", truth: index.even? ? "low_dissolved_oxygen" : "unknown",
                                       facts: {"dissolved_oxygen" => index.even? ? 1.2 : 4.0}) }
    baselines = Tamoz::Evals::Benchmark::Baselines
    %i[majority_prior random_label fixed_threshold z_score first_difference
       moving_median nearest_symptom deterministic_detector].each do |name|
      first = baselines.public_send(name, cells, CODES)
      second = baselines.public_send(name, cells, CODES)
      assert_equal first.map { |cell| cell.fetch("primary_code") },
                   second.map { |cell| cell.fetch("primary_code") },
                   "#{name} must be deterministic"
    end
  end

  def test_baseline_detectors_alarm_on_a_metric_crash
    cells = [
      cell(primary: "unknown", truth: "low_dissolved_oxygen",
           facts: {"dissolved_oxygen" => 1.0, "dissolved_oxygen_series" => [4.0, 3.0, 1.0]}),
      cell(primary: "unknown", truth: "unknown",
           facts: {"dissolved_oxygen" => 4.2, "dissolved_oxygen_series" => [4.4, 4.3, 4.2]})
    ]
    z = Tamoz::Evals::Benchmark::Baselines.z_score(cells, CODES)
    assert_equal "low_dissolved_oxygen", z.first.fetch("primary_code")
  end

  def test_comparison_meets_minimum_effect_only_when_the_ci_clears_it
    comparison = Tamoz::Evals::Benchmark::Comparison.new
    strong = 20.times.map { |index| cell(cell_id: "c-#{index}", primary: "low_dissolved_oxygen",
                                          truth: "low_dissolved_oxygen") }
    weak = 20.times.map { |index| cell(cell_id: "c-#{index}", primary: "unknown",
                                        truth: "low_dissolved_oxygen") }
    result = comparison.paired(
      candidate: strong, baseline: weak, cells: strong,
      metric: ->(cell) { cell.fetch("primary_code") == cell.fetch("truth_code") ? 1.0 : 0.0 },
      minimum_effect: 0.05
    )
    assert result.fetch("meets_minimum_effect")
    assert_operator result.fetch("mean_difference"), :>, 0.5

    reversal = comparison.paired(
      candidate: weak, baseline: strong, cells: weak,
      metric: ->(cell) { cell.fetch("primary_code") == cell.fetch("truth_code") ? 1.0 : 0.0 },
      minimum_effect: 0.05
    )
    refute reversal.fetch("meets_minimum_effect")
  end

  def test_comparison_is_seed_deterministic
    comparison = Tamoz::Evals::Benchmark::Comparison.new
    cells = 10.times.map { |index| cell(cell_id: "c-#{index}", primary: "low_dissolved_oxygen",
                                        truth: index.even? ? "low_dissolved_oxygen" : "unknown") }
    metric = ->(cell) { cell.fetch("primary_code") == cell.fetch("truth_code") ? 1.0 : 0.0 }
    first = comparison.paired(candidate: cells, baseline: cells.reverse, cells:, metric:,
                              minimum_effect: 0.05)
    second = comparison.paired(candidate: cells, baseline: cells.reverse, cells:, metric:,
                               minimum_effect: 0.05)
    assert_equal first.fetch("mean_difference"), second.fetch("mean_difference")
    assert_equal first.fetch("ci_low"), second.fetch("ci_low")
    assert_equal first.fetch("ci_high"), second.fetch("ci_high")
  end

  def report(protocol, cells, model_identity: "local-model", label: "", controls_passed: false, go_baseline_cells: nil)
    Tamoz::Evals::Benchmark::Report.build(
      protocol:,
      cells:,
      model_identity:,
      label:,
      controls_passed:,
      go_baseline_cells:,
      protocol_sha256: "5e25b0b9de404ceb2f209da9f141f696e0a6f3215cdce6c9307a4f4cf0c66e4a"
    )
  end

  def protocol
    read_json(ROOT.join("docs", "benchmark", "BENCHMARK_PROTOCOL.json"))
  end

  def test_report_binds_the_protocol_and_never_claims_a_go_for_pilot_cells
    perfect = 10.times.map do |index|
      cell(cell_id: "pilot-#{index}", label: "pilot", primary: "low_dissolved_oxygen",
           truth: "low_dissolved_oxygen")
    end
    built = report(protocol, perfect, controls_passed: true)
    assert_equal "1.0.0", built.fetch("benchmark_protocol_version")
    assert_equal "5e25b0b9de404ceb2f209da9f141f696e0a6f3215cdce6c9307a4f4cf0c66e4a",
                 built.fetch("protocol_sha256")
    assert_equal "inconclusive", built.fetch("verdict"),
                 "a pilot (fixture) run must never claim the go rule"
    assert_match(/\Asha256:[0-9a-f]{64}\z/, built.fetch("content_digest"))
  end

  # The critical regression: cells as the harness ACTUALLY emits them (the
  # label carried through extract) — even a perfect candidate with the control
  # gate passed must stay inconclusive because the label is pilot.
  def test_report_never_claims_a_go_for_pilot_cells_even_when_the_candidate_wins
    # 2 families × 5 cells, all correct: the strongest baseline is the
    # majority prior, and the candidate beats it on every cell.
    cells = 5.times.map do |index|
      cell(cell_id: "a-#{index}", label: "pilot", scenario_family: "do-crash",
           primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen",
           facts: {"dissolved_oxygen" => 1.0})
    end + 5.times.map do |index|
      cell(cell_id: "b-#{index}", label: "pilot", scenario_family: "climate-deviation",
           primary: "overheated", truth: "overheated",
           facts: {"zone_temperature" => 33.0})
    end
    built = report(protocol, cells, controls_passed: true)
    assert_equal "inconclusive", built.fetch("verdict"),
                 "a pilot run must NEVER claim go even when the candidate beats every baseline"
  end

  def test_report_surfaces_failed_cells_and_flags_unreported_attempts
    produced = cell(cell_id: "ok-1", primary: "low_dissolved_oxygen", truth: "low_dissolved_oxygen")
    failed = cell(cell_id: "bad-1", primary: nil, truth: "low_dissolved_oxygen")
               .merge("status" => "failed", "failure_reason" => "episode/typed_failure")
    built = report(protocol, [produced, failed])
    assert_equal 1, built.fetch("failed_cell_count")
    assert_includes built.fetch("stop_rule_violations"), "unreported_attempt"
    assert_equal "inconclusive", built.fetch("verdict")
  end

  def test_report_refuses_a_go_without_the_control_gate
    cells = 10.times.map do |index|
      cell(cell_id: "real-#{index}", label: "holdout", primary: "low_dissolved_oxygen",
           truth: "low_dissolved_oxygen")
    end
    assert_equal "inconclusive", report(protocol, cells, controls_passed: false).fetch("verdict"),
                 "the go rule requires the preregistered controls to have passed"
  end

  def test_report_negative_when_the_candidate_loses_to_the_strongest_baseline
    # A candidate that always misses while the z-score detector catches the
    # crash: the comparison is negative and the report says so plainly.
    crash_cells = 8.times.map do |index|
      cell(cell_id: "c-#{index}", primary: "equipment_failure", truth: "low_dissolved_oxygen",
           facts: {"dissolved_oxygen" => 1.0, "dissolved_oxygen_series" => [4.0, 3.0, 1.0]})
    end
    calm_cells = 4.times.map do |index|
      cell(cell_id: "n-#{index}", primary: "unknown", truth: "unknown",
           facts: {"dissolved_oxygen" => 4.0, "dissolved_oxygen_series" => [4.2, 4.1, 4.0]})
    end
    built = report(protocol, crash_cells + calm_cells)
    assert_includes %w[negative inconclusive], built.fetch("verdict")
    assert_includes protocol.fetch("baselines"), built.fetch("strongest_baseline")
    strongest = built.fetch("baselines").find { |row| row.fetch("name") == built.fetch("strongest_baseline") }
    assert_operator strongest.fetch("macro_f1"), :>, 0.0,
                    "a detector that catches the crash must beat the always-wrong candidate"
  end
end
