# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_fixtures'

# The run record, and budget changes only as approved
# candidates built from development runs.
# rubocop:disable Minitest/MultipleAssertions -- each row reads one record or candidate from several sides.
class ResearchTuningTest < Minitest::Test
  include ResearchFixtures

  Improvement = Tamoz::Agent::Improvement

  def setup
    @budgets = R.budgets
  end

  def test_the_run_record_carries_the_numbers_tuning_learns_from
    record = tuning_record(tokens: { 'total' => { 'prompt_tokens' => 120 } }, support_rate: 0.5)

    assert_equal 'factual', record.fetch('question_class')
    assert_equal 'quick', record.fetch('depth')
    assert_equal 120, record.dig('tokens', 'total', 'prompt_tokens')
    assert_in_delta 0.5, record.fetch('support_rate')
    assert_equal [1], record.fetch('claims_per_wave')
    assert_equal record.fetch('claims'), record.fetch('claims_per_wave').sum
    %w[children waves searches page_reads stop_reason statuses].each { |field| assert_includes record, field }
  end

  def test_a_plan_without_a_known_question_class_is_refused
    error = assert_raises(Tamoz::Research::Error) { plan('question_class' => 'trivia') }

    assert_includes error.message, 'question_class must be one of'
  end

  def test_the_plan_tool_offers_exactly_the_classes_the_gem_accepts
    tool = Tamoz::Harness::ResearchPack.tools(:lead).find { |schema| schema.name == 'propose_research_plan' }
    offered = tool.parameters.dig('properties', 'question_class', 'enum')

    offered.each { |name| assert_equal name, plan('question_class' => name).question_class }
  end

  def test_a_candidate_that_raises_a_number_is_refused
    error = assert_raises(Tamoz::Research::Error) do
      R.budgets(override: { 'depths' => { 'quick' => { 'waves' => 9 } } })
    end

    assert_includes error.message, 'may only lower'
  end

  def test_saturated_runs_propose_one_wave_fewer
    tuner = tuner_for([saturated('dev-1'), saturated('dev-2'), tuning_record(run_id: 'dev-3', waves: 2)])

    assert_equal({ 'depths' => { 'quick' => { 'waves' => 1 } } }, tuner.candidate_content)
    assert_equal 1, tuner.budgets.depth('quick').waves
  end

  def test_runs_that_did_not_saturate_propose_nothing
    assert_empty tuner_for([tuning_record(run_id: 'dev-1', waves: 2)]).candidate_content
  end

  def test_the_candidate_is_powerless_until_its_exact_digest_is_approved
    tuner = tuner_for([saturated('dev-1')])
    lifecycle = lifecycle_for(tuner)
    lifecycle.validate!

    error = assert_raises(Improvement::ApprovalDigestError) do
      lifecycle.approve!(approval_digest: 'sha256:another-candidate', evidence: 'human:tamoz.agent.improvement')
    end
    assert_includes error.message, 'does not bind the exact candidate'

    request = lifecycle.approval_request(operation: :apply)
    lifecycle.approve!(approval_digest: request.fetch('approval_digest'), evidence: 'human:tamoz.agent.improvement')

    assert_equal R.budgets.to_h, @budgets.to_h, 'approving a candidate changed the shipped budgets'
  end

  def test_a_held_out_run_is_refused_as_a_tuning_input
    error = assert_raises(ArgumentError) { tuner_for([saturated('dev-1'), saturated('held-out-1')]) }

    assert_includes error.message, 'held-out-1'
  end

  private

  def lifecycle_for(tuner)
    proposal = Improvement::CandidateLifecycle.propose(
      thread_id: 'research-tuning', profile_id: 'research', scope: 'config', created_by: 'operator',
      from_digest: Tamoz::Core.digest("tamoz.research.budgets.v1\n", @budgets.to_h), to_digest: tuner.candidate_digest
    )
    Improvement::CandidateLifecycle.new(proposal:, candidate_resolver: ->(_id) { tuner.candidate(proposal:) })
  end

  def tuner_for(records) = Improvement::ResearchBudgetTuner.new(records:, holdout_ids: %w[held-out-1 held-out-2])

  def saturated(run_id) = tuning_record(run_id:, waves: 2, stop_reason: 'saturation')

  def tuning_record(tokens: nil, support_rate: nil, stop_reason: 'budget', **extra)
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true))])
    report = R.report({ 'summary' => 'Summary.', 'body' => 'Fact [C1].' }, ledger:, stop_reason:)
    R.run_record(ledger:, report:, stop_reason:,
                 extra: { 'tokens' => tokens, 'support_rate' => support_rate }.merge(extra.transform_keys(&:to_s)))
  end
end
# rubocop:enable Minitest/MultipleAssertions
