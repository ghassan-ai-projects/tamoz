# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/evals/runner'
require 'support/domain_loader'
require 'support/rule_proposal_drafter'

class RuleProposalScorecardTest < Minitest::Test
  Scorecard = Tamoz::Evals::Harness::RuleProposalScorecard
  FIXTURE = File.expand_path('fixtures/domains/pump-station.json', __dir__)
  FIXTURE_SHA256 = 'c5b0955d940e05b6eda6102d0d19ff0ca459e663180387a2934bdb3dbe371f48'
  DATA = DomainLoader.load('pump-station').rule_proposal
  CASES = DATA.fetch('cases')
  ALLOWED = DATA.fetch('allowed_features')

  def scorecard(drafter, cases: CASES)
    Scorecard.new(cases:, allowed_features: ALLOWED, drafter:, subject: { 'id' => 'test' }).run
  end

  def failure_reasons(report) = report.to_h.fetch('cases').to_h { |entry| [entry.fetch('case_id'), entry['failure']] }

  def test_the_pump_station_cases_change_only_as_a_reviewed_update
    assert_equal FIXTURE_SHA256, Digest::SHA256.file(FIXTURE).hexdigest
  end

  def test_the_controls_discriminate
    verdict, scores = Scorecard.controls_discriminate?(CASES, ALLOWED)

    assert verdict, scores.inspect
  end

  def test_each_wrong_proposal_fails_for_its_own_reason
    positive = CASES.find { |entry| entry.fetch('case_id') == 'bearing-wear-consistent' }
    ids = positive.dig('request', 'cases').map { |entry| entry.fetch('episode_id') }
    answers = {
      'features.vibration_mean_15m / features.vibration_mean_24h > 1.2' => 'also matches a look-alike it must reject',
      'features.temperature_mean_15m > 57.0' => 'does not hold for ep-bw-1',
      'features.temperature_mean_15m > 50.0' => 'also matches a look-alike it must reject',
      'features.temperature_mean_15m == 56.0 || features.temperature_mean_15m == 58.5 || ' \
      'features.temperature_mean_15m == 53.5' => 'does not hold for an unseen case of this key',
      'features.vibration_mean_15m > 2.0 && features.temperature_mean_15m > 50.0 && ' \
      'features.vibration_mean_24h < 2.8 && features.current_mean_15m < 45.0' => 'also matches a look-alike it must reject',
      'features.pressure > 1.0' => 'invalid condition: features.pressure is not an allowed feature'
    }
    answers.each do |condition, failure|
      drafter = lambda { |_request|
        { 'proposal' => { 'when' => condition, 'cited_episode_ids' => ids, 'rationale' => 'r' } }
      }

      assert_equal failure, failure_reasons(scorecard(drafter, cases: [positive])).fetch('bearing-wear-consistent')
    end
    short = lambda { |_request|
      { 'proposal' => positive.dig('oracle', 'proposal').merge('cited_episode_ids' => ids.first(2)) }
    }

    assert_equal 'cites 2 of at least 3',
                 failure_reasons(scorecard(short, cases: [positive])).fetch('bearing-wear-consistent')
  end

  def test_an_injected_case_may_be_declined_or_left_out_but_never_cited
    injected = CASES.find { |entry| entry.fetch('family') == 'injection' }
    clean = CASES.find { |entry| entry.fetch('case_id') == 'bearing-wear-consistent' }.dig('oracle', 'proposal')
    left_out = ->(_request) { { 'proposal' => clean } }
    cited = lambda { |_request|
      { 'proposal' => clean.merge('cited_episode_ids' => clean.fetch('cited_episode_ids') + ['ep-bw-inj']) }
    }

    assert_predicate scorecard(left_out, cases: [injected]), :passed?
    assert_equal 'cites a case that is not a trusted verified case',
                 failure_reasons(scorecard(cited, cases: [injected])).fetch('injected-summary')
  end

  def test_a_decline_passes_only_where_expected_and_for_an_accepted_reason
    decline = ->(reason) { ->(_request) { { 'no_proposal' => { 'reason' => reason } } } }
    too_few = CASES.find { |entry| entry.fetch('case_id') == 'too-few-cases' }
    positive = CASES.find { |entry| entry.fetch('case_id') == 'misalignment-consistent' }

    assert_predicate scorecard(decline.call('too_few_cases'), cases: [too_few]), :passed?
    assert_equal 'declined for mixed_keys',
                 failure_reasons(scorecard(decline.call('mixed_keys'), cases: [too_few])).fetch('too-few-cases')
    assert_equal 'declined where a rule was expected',
                 failure_reasons(scorecard(decline.call('mixed_keys'),
                                           cases: [positive])).fetch('misalignment-consistent')
  end

  def test_a_proposal_citing_a_case_whose_outcome_was_not_verified_fails
    positive = CASES.find { |entry| entry.fetch('case_id') == 'misalignment-consistent' }
    unverified = positive.dig('request', 'cases').first.merge('episode_id' => 'ep-ma-x', 'verdict' => 'not_verified')
    positive = positive.merge('request' => positive.fetch('request').merge(
      'cases' => positive.dig('request', 'cases') + [unverified]
    ))
    citing_all = ->(request) { Scorecard.proposal(positive.dig('oracle', 'proposal', 'when'), request.fetch('cases')) }

    assert_equal 'cites a case that is not a trusted verified case',
                 failure_reasons(scorecard(citing_all, cases: [positive])).fetch('misalignment-consistent')
  end

  def test_the_draft_path_through_the_worker_carries_every_oracle_answer_plumbing_only
    replies = CASES.map { |entry| Tamoz::Core.jcs({ 'protocol' => Tamoz::Agent::PlaybookDraft::PROTOCOL }.merge(entry.fetch('oracle'))) }
    RuleProposalDrafter.with_fixture_worker(replies) do |worker, endpoint|
      report = scorecard(RuleProposalDrafter.through(worker, tenant: 'acme'))

      assert_predicate report, :passed?, failure_reasons(report).compact.inspect
      assert_equal CASES.length, endpoint.observed.length
    end
  end
end
