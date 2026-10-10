# frozen_string_literal: true

require_relative 'test_helper'

# The durable path every channel rides: each settled turn that failed, and each crashed request, emits a
# `healing.assessment` operator event and, when nothing can fix it, tells the turn's channel after its reply.
class SelfHealingWorkerTest < Minitest::Test
  class RuntimeDouble
    attr_reader :delivered

    def initialize = @delivered = []
    def delivery_sink = self
    def push(**message) = @delivered << message
    def close_occurrence(_thread_id) = nil
    def occurrence_age_milliseconds(_thread_id) = 0
    def durably_fail_request(*, **) = nil
    def child_task(_thread_id) = nil
  end

  def setup
    @events = []
    @runtime = RuntimeDouble.new
    @worker = Tamoz::Agent::Worker.new(runtime: @runtime, session_builder: ->(_thread) {},
                                       emitter: ->(document) { @events << document })
  end

  def view(status, reason, observations: [], satisfied: false)
    Tamoz::Agent::SessionView.new(
      thread_id: 'telegram.thread', checkpoint_id: 'c1', sequence: 1, execution_id: 'e1', request_id: 'r1', status:,
      phase: 'terminal', accepted_plan: nil, approvals: [], effect_receipts: [], blocked: nil,
      terminal: { 'reason' => reason, 'satisfied' => satisfied }, provider_ambiguity: nil, interrupts: [],
      state: { terminal_reason: reason, observations:, verification: { 'answer' => 'Hi.', 'satisfied' => satisfied } }
    )
  end

  def settle(view)
    @worker.send(:settle_view, view, 'telegram.thread', 'r1', 5)
    @events.find { |document| document['event'] == 'healing.assessment' }&.fetch('assessment')
  end

  def failed_check
    [{ 'tool' => 'run_check', 'check' => { 'name' => 'values', 'outcome' => 'exit_1', 'passed' => false } }]
  end

  def repaired_tool_failure
    [{ 'tool' => 'apply_patch', 'failure' => { 'tool' => 'apply_patch', 'error_class' => 'Tamoz::Agent::ToolArgumentError',
                                               'reason' => 'bad' } }]
  end

  def test_a_failed_turn_is_classified_from_its_observations
    assessment = settle(view(:failed, 'repair_attempts_exhausted', observations: failed_check))

    assert_equal 'verification_failed', assessment.fetch('category')
    assert_equal 'escalated', assessment.fetch('route')
  end

  def notices = @runtime.delivered.select { |push| push[:kind] == 'healing.escalated' }

  def test_an_escalated_failure_is_told_to_its_channel_after_its_reply
    settle(view(:completed, 'work_failed'))

    assert_equal(%w[request.completed healing.escalated], @runtime.delivered.map { |push| push[:kind] })
    assert_equal 'r1', notices.first.fetch(:request_id)
    assert_includes notices.first.fetch(:text), 'escalated to you. Reference: r1'
  end

  def test_a_failure_a_rule_can_fix_sends_no_notice
    remediable = Tamoz::Agent::SelfHealingAssessor::Assessment.new(
      remediable: true, route: :remediate, category: :stale_precondition, action_family: :refresh_recompute,
      rule_id: 'rule.x', never_mutate_class: nil, fingerprint: 'sha256:x', confidence: 1.0
    )
    healing = Object.new
    healing.define_singleton_method(:assess_turn) { |*, **| remediable }
    worker = Tamoz::Agent::Worker.new(runtime: @runtime, session_builder: ->(_thread) {}, emitter: ->(_) {}, healing:)
    worker.send(:settle_view, view(:completed, 'work_failed'), 'telegram.thread', 'r1', 5)

    assert_empty notices
  end

  def test_a_crashed_request_is_told_to_its_channel
    entry = { thread_id: 'telegram.thread', head_request_id: 'r1', head_status: :queued }
    @worker.send(:handle_thread_failure, entry, Tamoz::CheckpointConflictError.new('lease'))

    assert_equal(%w[request.failed healing.escalated], @runtime.delivered.map { |push| push[:kind] })
  end

  def test_a_clean_turn_sends_no_notice
    settle(view(:completed, 'answered', satisfied: true))

    assert_empty notices
  end

  def test_a_model_refusal_is_classified_from_its_terminal_reason
    assert_equal 'dependency_unavailable', settle(view(:completed, 'model_provider_down')).fetch('category')
  end

  def test_a_chat_turn_that_stopped_itself_is_classified
    assert_equal 'unknown', settle(view(:completed, 'work_failed')).fetch('category')
    @events.clear

    assert_equal 'resource_exhausted', settle(view(:completed, 'handed_off')).fetch('category')
  end

  def test_a_blocked_turn_is_an_unknown_effect
    assert_equal 'effect_unknown', settle(view(:blocked, 'effect_unknown')).fetch('category')
  end

  def test_a_finished_turn_is_not_assessed_even_after_a_repaired_tool_failure
    assert_nil settle(view(:completed, 'answered', observations: repaired_tool_failure, satisfied: true))
    assert_nil settle(view(:completed, 'done', satisfied: true))
  end

  def test_a_crashed_request_is_assessed
    entry = { thread_id: 'telegram.thread', head_request_id: 'r1', head_status: :queued }
    @worker.send(:handle_thread_failure, entry, Tamoz::CheckpointConflictError.new('lease'))

    assessment = @events.find { |document| document['event'] == 'healing.assessment' }.fetch('assessment')

    assert_equal 'unknown', assessment.fetch('category')
    assert_equal 'escalated', assessment.fetch('route')
  end

  def test_a_recovery_retry_is_not_assessed
    entry = { thread_id: 'telegram.thread', head_request_id: 'r1', head_status: :running }
    @worker.send(:handle_thread_failure, entry, Tamoz::CheckpointConflictError.new('lease'))

    assert_nil(@events.find { |document| document['event'] == 'healing.assessment' })
  end
end
