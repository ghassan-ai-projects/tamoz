# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/investigation_control_gate'

# Measurement plan 16, offline. The grader is trusted only if it tells an oracle that reads the evidence from
# controls that never look, guess, probe blindly, query without aim, forge a citation, or try to act, and if the
# fixture server served exactly the reads the graph dispatched. Scripted controls: this proves the grader, never
# the model.
class InvestigationEvalControlsTest < Minitest::Test
  def test_every_control_trips_the_gate_it_is_meant_to
    assert_empty InvestigationControlGate.control_failures(InvestigationControlGate.control_summaries)
  end

  def test_the_corpus_is_checked_against_the_diagnosis_catalog
    corpus = JSON.parse(File.read(InvestigationEval::CORPUS_PATH))
    corpus['cells'].first['truth'] = 'bad_luck'

    assert_raises(ArgumentError) { InvestigationEval.check_codes(corpus) }
  end

  def test_the_interval_is_a_wilson_interval
    assert_equal [0.4902, 0.9433], InvestigationGrader.rate(8, 10).fetch('interval')
    assert_nil InvestigationGrader.rate(0, 0).fetch('value')
  end
end
