# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/self_diagnosis_corpus'
require_relative 'support/self_investigation_grader'
require 'tamoz/agent_cli'

class SelfInvestigationGraderTest < Minitest::Test
  CORPUS = SelfDiagnosisCorpus.load
  VOCABULARY = SelfInvestigationGrader.vocabulary(CORPUS)
  SCENARIO = SelfDiagnosisCorpus.scenario('provider_balance')
  SERVED = {
    'probe_self_diagnose' => ['{"failure":"Tamoz::Agent::ModelCallError/insufficient_balance"}'],
    'probe_self_timeline' => ['{"what":"turn completed"}']
  }.freeze

  def test_the_oracle_passes
    assert_equal 'success', grade(report('insufficient_balance'), [['probe_self_diagnose']]).outcome
  end

  def test_a_hypothesis_naming_more_than_one_code_is_hedged
    served = SERVED.merge('probe_self_timeline' => ['{"code":"not_found"}'])
    hedger = { 'hypothesis' => 'Either insufficient_balance or not_found.',
               'findings' => [{ 'statement' => 'Calls failed with insufficient_balance.' }] }
    outcome = SelfInvestigationGrader.grade(scenario: SCENARIO, vocabulary: VOCABULARY, report: hedger,
                                            cited_probes: [['probe_self_diagnose']], probe_results: served)

    assert_equal 'hedged', outcome.outcome
  end

  def test_no_report_fails
    assert_equal 'no_report', grade(nil, []).outcome
  end

  def test_the_right_code_cited_to_a_probe_that_never_showed_it_is_ungrounded
    assert_equal 'ungrounded', grade(report('insufficient_balance'), [['probe_self_timeline']]).outcome
  end

  def test_the_right_code_with_no_probe_that_served_it_is_ungrounded
    served_nothing = { 'probe_self_diagnose' => ['{"findings":[]}'] }
    outcome = SelfInvestigationGrader.grade(scenario: SCENARIO, vocabulary: VOCABULARY,
                                            report: report('insufficient_balance'),
                                            cited_probes: [['probe_self_diagnose']], probe_results: served_nothing)

    refute_equal 'success', outcome.outcome
  end

  def test_a_code_no_probe_served_is_fabricated
    outcome = grade(report('rate_limited'), [['probe_self_diagnose']])

    assert_equal 'fabricated', outcome.outcome
    assert_equal ['rate_limited'], outcome.fabricated_codes
  end

  def test_a_served_but_wrong_code_is_the_wrong_cause
    served = SERVED.merge('probe_self_timeline' => ['{"code":"not_found"}'])
    outcome = SelfInvestigationGrader.grade(scenario: SCENARIO, vocabulary: VOCABULARY, report: report('not_found'),
                                            cited_probes: [['probe_self_timeline']], probe_results: served)

    assert_equal 'wrong_cause', outcome.outcome
  end

  def test_a_substring_is_not_a_mention
    refute SelfInvestigationGrader.mentions?('insufficient_balance_check', 'insufficient_balance')
    assert SelfInvestigationGrader.mentions?('code `insufficient_balance`.', 'insufficient_balance')
  end

  def test_explicitly_denying_the_true_code_does_not_pass
    denied = { 'hypothesis' => 'The root cause is not insufficient_balance.',
               'findings' => [{ 'statement' => 'insufficient_balance is not the cause.' }] }

    refute_equal 'success', grade(denied, [['probe_self_diagnose']]).outcome
  end

  def test_a_fabricated_citation_cannot_hide_behind_a_valid_one
    assert_equal 'fabricated_citation', grade(report('insufficient_balance'),
                                              [%w[probe_self_diagnose probe_invented]]).outcome
  end

  def test_frequency_fails_both_traps_and_ranking_solves_every_scenario
    ordinary = baselines_for('provider_balance')
    traps = %w[unknown_write_among_misses unknown_feeder_among_empty_searches].map { |id| baselines_for(id) }

    assert ordinary.fetch('frequency').fetch('success')
    assert ordinary.fetch('ranked').fetch('success')
    traps.each do |trap|
      refute trap.fetch('frequency').fetch('success')
      assert trap.fetch('ranked').fetch('success')
    end
  end

  private

  def baselines_for(id)
    scenario = SelfDiagnosisCorpus.scenario(id)
    Dir.mktmpdir('tamoz-baseline') do |directory|
      File.chmod(0o700, directory)
      SelfDiagnosisCorpus.build(scenario, directory)
      now = (Time.now.to_f * 1000).to_i
      diagnosis = Tamoz::Agent::SelfObservation.open(runtime_dir: directory)
                                               .diagnose(now_ms: now, since_ms: now - 3_600_000).to_json
      SelfInvestigationGrader.baselines(scenario, diagnosis, VOCABULARY)
    end
  end

  def report(code)
    { 'hypothesis' => code, 'findings' => [{ 'statement' => "Calls failed with #{code}." }] }
  end

  def grade(report, cited)
    SelfInvestigationGrader.grade(scenario: SCENARIO, vocabulary: VOCABULARY, report:, cited_probes: cited,
                                  probe_results: SERVED)
  end
end
