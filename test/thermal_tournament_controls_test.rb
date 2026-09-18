# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'support/thermal_tournament'

# The discrimination gate for the physical/thermal surface (GAPS-20260918 G4).
#
# thermal_tournament_test proves the governed supervisor beats the fixed-threshold
# BASELINE. That is one opponent. This proves the scoring also separates the
# supervisor from the two trivial strategies a metric can be fooled by:
#
#   null      — abstains on every cell (does nothing).
#   adversary — acts on every cell (trusts the number, ignores sensor quality).
#
# The governed supervisor must beat BOTH, and the safety-weighted metric
# (counterfactual regret, missed action ≫ false alarm) must rank them
# supervisor < adversary < null-by-regret. If a trivial strategy scored as well
# as the governed one, the tournament would not be measuring judgment.
class ThermalTournamentControlsTest < Minitest::Test
  Metrics = Tamoz::Evals::Benchmark::Metrics
  Comparison = Tamoz::Evals::Benchmark::Comparison

  def setup
    @dir = Dir.mktmpdir('tamoz-tourney-controls')
    @tourney = ThermalTournament.new(@dir)
    @supervisor = @tourney.supervisor_cells
    @null = @tourney.null_supervisor_cells
    @adversary = @tourney.adversary_supervisor_cells
  end

  def teardown
    @tourney&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def correct
    ->(cell) { Metrics.abstained?(cell) == (cell.fetch('abstain_expected') == true) ? 1.0 : 0.0 }
  end

  # The supervisor is perfect on this corpus; both trivial strategies are not.
  def test_governed_supervisor_beats_both_trivial_controls_on_accuracy
    supervisor = Metrics.mean(@supervisor.map { |c| correct.call(c) })
    null = Metrics.mean(@null.map { |c| correct.call(c) })
    adversary = Metrics.mean(@adversary.map { |c| correct.call(c) })

    assert_operator supervisor, :>, null, 'governed judgment must beat blanket abstention'
    assert_operator supervisor, :>, adversary, 'governed judgment must beat blanket action'
  end

  # Regret is the safety-weighted metric: a missed action dwarfs a false alarm.
  # The governed supervisor carries zero regret; the controls do not.
  def test_regret_separates_the_supervisor_from_both_controls
    supervisor = Metrics.counterfactual_regret(@supervisor)
    null = Metrics.counterfactual_regret(@null)
    adversary = Metrics.counterfactual_regret(@adversary)

    assert_in_delta 0.0, supervisor, 1e-9
    assert_operator null, :>, adversary, 'a missed catastrophe must cost more than blanket false alarms'
    assert_operator adversary, :>, supervisor
  end

  def test_paired_comparison_favours_the_supervisor_over_each_control
    [@null, @adversary].each do |control|
      result = Comparison.new.paired(
        candidate: @supervisor, baseline: control, cells: @supervisor,
        metric: correct, minimum_effect: 0.0, seed: 7
      )
      assert_operator result.fetch('mean_difference'), :>, 0.0
    end
  end

  # G2 (corpus balance): the corpus was 7:1 abstain:act, where a do-nothing null
  # supervisor scored 7/8 and plain accuracy barely separated it from the governed
  # one. The corpus now carries four acting cells, so accuracy itself discriminates
  # — not only the asymmetric-cost regret. This guard fails if the corpus regresses
  # toward the imbalance.
  def test_corpus_is_balanced_enough_for_accuracy_to_discriminate
    supervisor = Metrics.mean(@supervisor.map { |c| correct.call(c) })
    null = Metrics.mean(@null.map { |c| correct.call(c) })
    acting = @supervisor.count { |c| c.fetch('abstain_expected') != true }

    assert_operator acting, :>=, 4, 'the corpus must carry enough acting cells to separate null'
    assert_operator supervisor - null, :>=, 0.3,
                    'accuracy alone now separates null from the supervisor on the balanced corpus'
  end
end
