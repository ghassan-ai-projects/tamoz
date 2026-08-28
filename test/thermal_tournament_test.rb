# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "support/thermal_tournament"

# Real-world sensor WP-T3: the shadow tournament, scored end to end. The baseline
# is real; the supervisor's decisions are governed by the real graph over a
# labelled fixture proposal. This pins the tournament MECHANICS — that the scoring
# rewards a supervisor which abstains on the conflict cells over a threshold
# baseline that false-alarms on them. It is NOT an intelligence result: that is
# the real-model headline run (memory/real-llm-not-fake.md).
class ThermalTournamentTest < Minitest::Test
  Metrics = Tamoz::Evals::Benchmark::Metrics
  Comparison = Tamoz::Evals::Benchmark::Comparison

  def setup
    @dir = Dir.mktmpdir("tamoz-tourney")
    @tourney = ThermalTournament.new(@dir)
    @baseline = @tourney.baseline_cells
    @supervisor = @tourney.supervisor_cells
  end

  def teardown
    @tourney&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  # The baseline's genuine blind spot: it acts on the disconnected-sensor cell
  # because it trusts the number, ignoring the quality fact.
  def test_baseline_false_alarms_on_the_disconnected_sensor
    cell = @baseline.find { |c| c.fetch("cell_id") == "insufficient-evidence" }
    assert_equal ["R2"], cell.fetch("intent_risk_classes"),
                 "the fixed-threshold baseline alarms on a disconnected sensor's reading"
  end

  def test_supervisor_acts_only_on_the_clear_excursion
    acting = @supervisor.reject { |cell| Metrics.abstained?(cell) }.map { |cell| cell.fetch("cell_id") }
    assert_equal ["sustained-rise"], acting,
                 "the supervisor acts on the one clear excursion and abstains on the conflict cells"
  end

  def test_abstention_quality_rewards_the_supervisor
    assert_in_delta 1.0, Metrics.abstention_quality(@supervisor), 1e-9
    assert_in_delta 0.5, Metrics.abstention_quality(@baseline), 1e-9
    assert_operator Metrics.abstention_quality(@supervisor), :>, Metrics.abstention_quality(@baseline)
  end

  def test_counterfactual_regret_is_lower_for_the_supervisor
    assert_in_delta 0.0, Metrics.counterfactual_regret(@supervisor), 1e-9
    assert_operator Metrics.counterfactual_regret(@baseline), :>, 0.0
  end

  # The paired comparison (cluster bootstrap over the two scenario families)
  # favours the supervisor on the correctness metric, clearing a zero minimum
  # effect. The number is the harness working, not a model being smart.
  def test_paired_comparison_favours_the_supervisor
    correct = ->(cell) { Metrics.abstained?(cell) == (cell.fetch("abstain_expected") == true) ? 1.0 : 0.0 }
    result = Comparison.new.paired(
      candidate: @supervisor, baseline: @baseline, cells: @supervisor,
      metric: correct, minimum_effect: 0.0, seed: 7
    )
    assert_operator result.fetch("mean_difference"), :>, 0.0
    assert_operator result.fetch("clusters"), :>=, 2, "the bootstrap draws over ≥2 scenario families"
  end
end
