# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/evals/runner'
require 'tamoz/stream/draft_runner'
require 'support/domain_loader'
require 'support/episode_composition'
require 'support/local_model_endpoint'
require 'support/rule_proposal_drafter'

class RuleProposalScorecardTest < Minitest::Test
  Scorecard = Tamoz::Evals::Harness::RuleProposalScorecard
  FIXTURE = File.expand_path('fixtures/domains/pump-station.json', __dir__)
  FIXTURE_SHA256 = '2f3432ff1bd268711c21b8ec0a4ec34518f444d45ccd15b82389bd4d6c39b901'
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
    reports = Scorecard.control_drafters(CASES).transform_values do |drafter|
      scorecard(drafter).to_h.fetch('aggregate')
    end

    assert_equal CASES.length, reports.fetch('oracle').fetch('passed')
    %w[null adversary].each { |control| assert_equal 0, reports.fetch(control).fetch('passed'), control }
    assert_equal 0, reports.fetch('overfit').fetch('proposals_passed')
    declinable = CASES.count { |entry| !entry.fetch('abstain_expected') && entry.dig('gold', 'allow_decline') }

    assert_equal declinable, reports.fetch('decline').fetch('proposals_passed'),
                 'declining wins only where it is allowed'
    assert_operator reports.fetch('decline').fetch('abstentions_passed'), :<, reports.fetch('decline').fetch('abstentions_expected'),
                    'a decline for the wrong reason must fail'
  end

  def test_each_wrong_proposal_fails_for_its_own_reason
    positive = CASES.find { |entry| entry.fetch('case_id') == 'bearing-wear-consistent' }
    ids = positive.dig('request', 'cases').map { |entry| entry.fetch('episode_id') }
    answers = {
      'features.vibration_mean_15m / features.vibration_mean_24h > 1.2' => 'also matches a look-alike it must reject',
      'features.temperature_mean_15m > 57.0' => 'does not hold for ep-bw-1',
      'features.temperature_mean_15m > 50.0' => 'also matches a look-alike it must reject',
      'features.vibration_mean_15m / features.vibration_mean_24h > 1.26 && features.temperature_mean_15m > 54.0' =>
        'does not hold for an unseen case of this key',
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
    contradicting = CASES.find { |entry| entry.fetch('case_id') == 'contradicting-outcome' }
    positive = CASES.find { |entry| entry.fetch('case_id') == 'misalignment-consistent' }

    assert_predicate scorecard(decline.call('contradicting_cases'), cases: [contradicting]), :passed?
    assert_equal 'declined for too_few_cases',
                 failure_reasons(scorecard(decline.call('too_few_cases'),
                                           cases: [contradicting])).fetch('contradicting-outcome')
    assert_equal 'declined where a rule was expected',
                 failure_reasons(scorecard(decline.call('mixed_keys'),
                                           cases: [positive])).fetch('misalignment-consistent')
  end

  def test_a_proposal_citing_a_case_whose_outcome_was_not_verified_fails
    positive = CASES.find { |entry| entry.fetch('case_id') == 'misalignment-consistent' }
    citing_all = ->(request) { Scorecard.proposal(positive.dig('oracle', 'proposal', 'when'), request.fetch('cases')) }

    assert_equal 'cites a case that is not a trusted verified case',
                 failure_reasons(scorecard(citing_all, cases: [positive])).fetch('misalignment-consistent')
  end

  def test_the_draft_path_through_the_worker_carries_every_oracle_answer_plumbing_only
    replies = CASES.map { |entry| Tamoz::Core.jcs({ 'protocol' => Tamoz::Agent::PlaybookDraft::PROTOCOL }.merge(entry.fetch('oracle'))) }
    Dir.mktmpdir('tamoz-rule-eval') do |dir|
      endpoint = LocalModelEndpoint.new(mode: :fixture, responses: replies,
                                        log_path: File.join(dir, 'endpoint.log')).start
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      worker = Tamoz::Stream::EpisodeWorker.new(worker_version: 'test').bind_draft_runner(
        Tamoz::Stream::DraftRunner.new(durable_runner: composition.fetch(:app).durable_runner, tenant: 'acme',
                                       model_policy: 'fast')
      )

      report = scorecard(RuleProposalDrafter.through(worker, tenant: 'acme'))

      assert_predicate report, :passed?, failure_reasons(report).compact.inspect
      assert_equal CASES.length, endpoint.observed.length
    ensure
      endpoint&.stop
      composition&.fetch(:adapter)&.close
      FileUtils.remove_entry(composition.fetch(:directory)) if composition
    end
  end
end
