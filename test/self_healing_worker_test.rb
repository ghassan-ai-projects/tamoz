# frozen_string_literal: true

require_relative 'test_helper'

# The durable path every channel (queue, schedule, Telegram) rides: each settled turn that failed, and each
# crashed request, emits a `healing.assessment` operator event. Executes nothing; correspondents are unaffected.
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
    @worker = Tamoz::Agent::Worker.new(runtime: RuntimeDouble.new, session_builder: ->(_thread) {},
                                       emitter: ->(document) { @events << document })
  end

  def view(status, reason, observations: [], satisfied: false)
    Tamoz::Agent::SessionView.new(
      thread_id: 'tg.thread', checkpoint_id: 'c1', sequence: 1, execution_id: 'e1', request_id: 'r1', status:,
      phase: 'terminal', accepted_plan: nil, approvals: [], effect_receipts: [], blocked: nil,
      terminal: { 'reason' => reason, 'satisfied' => satisfied }, provider_ambiguity: nil, interrupts: [],
      state: { terminal_reason: reason, observations:, verification: { 'answer' => 'Hi.', 'satisfied' => satisfied } }
    )
  end

  def settle(view)
    @worker.send(:settle_view, view, 'tg.thread', 'r1', 5)
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
    entry = { thread_id: 'tg.thread', head_request_id: 'r1', head_status: :queued }
    @worker.send(:handle_thread_failure, entry, Tamoz::CheckpointConflictError.new('lease'))

    assessment = @events.find { |document| document['event'] == 'healing.assessment' }.fetch('assessment')

    assert_equal 'unknown', assessment.fetch('category')
    assert_equal 'escalated', assessment.fetch('route')
  end

  def test_a_recovery_retry_is_not_assessed
    entry = { thread_id: 'tg.thread', head_request_id: 'r1', head_status: :running }
    @worker.send(:handle_thread_failure, entry, Tamoz::CheckpointConflictError.new('lease'))

    assert_nil(@events.find { |document| document['event'] == 'healing.assessment' })
  end
end
