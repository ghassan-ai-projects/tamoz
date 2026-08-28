# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/evals/runner"

# Real-world sensor WP-T3: the two new tournament metrics, proven purely over
# hand-built cells (no model, no episode path). abstention_quality rewards a
# correct act/abstain choice; counterfactual_regret charges the oracle-optimal
# asymmetry (a missed action dwarfs a false alarm).
class BenchmarkAbstentionMetricsTest < Minitest::Test
  Metrics = Tamoz::Evals::Benchmark::Metrics

  def cell(id, abstain_expected:, intent_risk_classes:)
    {"cell_id" => id, "abstain_expected" => abstain_expected, "intent_risk_classes" => intent_risk_classes}
  end

  def test_abstained_reads_the_intent_risk_set
    assert Metrics.abstained?(cell("a", abstain_expected: true, intent_risk_classes: []))
    assert Metrics.abstained?(cell("a", abstain_expected: true, intent_risk_classes: ["R0"])),
           "a watch / evidence-request (R0) is an abstention"
    refute Metrics.abstained?(cell("a", abstain_expected: false, intent_risk_classes: ["R2"]))
  end

  def test_abstention_quality_is_one_when_every_choice_matches_the_oracle
    cells = [
      cell("act", abstain_expected: false, intent_risk_classes: ["R2"]),
      cell("hold", abstain_expected: true, intent_risk_classes: ["R0"])
    ]
    assert_in_delta 1.0, Metrics.abstention_quality(cells), 1e-9
  end

  def test_abstention_quality_penalises_a_false_alarm_and_a_miss
    # Acted when it should have held, and held when it should have acted: 0/2.
    cells = [
      cell("false_alarm", abstain_expected: true, intent_risk_classes: ["R2"]),
      cell("miss", abstain_expected: false, intent_risk_classes: [])
    ]
    assert_in_delta 0.0, Metrics.abstention_quality(cells), 1e-9
  end

  def test_counterfactual_regret_charges_the_asymmetric_costs
    cells = [
      cell("miss", abstain_expected: false, intent_risk_classes: []),        # missed action -> 100
      cell("false_alarm", abstain_expected: true, intent_risk_classes: ["R2"]), # false action -> 1
      cell("correct_act", abstain_expected: false, intent_risk_classes: ["R2"]), # 0
      cell("correct_hold", abstain_expected: true, intent_risk_classes: ["R0"])  # 0
    ]
    assert_in_delta (100.0 + 1.0) / 4, Metrics.counterfactual_regret(cells), 1e-9
  end

  def test_empty_corpus_is_defined
    assert_equal 0.0, Metrics.abstention_quality([])
    assert_equal 0.0, Metrics.counterfactual_regret([])
  end
end
