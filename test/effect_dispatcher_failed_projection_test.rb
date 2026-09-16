# frozen_string_literal: true

require_relative 'test_helper'

# CF04-REL-01: when an expired attempt succeeds late but the current attempt
# failed and the head is :failed, the failed projection must report the failure
# — not the historical success with error: nil, which would hide why the
# bounded repair path was skipped.
class EffectDispatcherFailedProjectionTest < Minitest::Test
  def test_failed_projection_reports_the_failure_not_a_late_success
    late_success = effect_attempt(1, :succeeded, result: 'late ok', error: nil)
    failure = effect_attempt(2, :failed, result: nil, error: { 'message' => 'provider refused' })
    record = effect_record([late_success, failure], current_attempt: 2)

    attempt = Tamoz::Agent::EffectDispatcher.send(:failed_attempt, record)

    assert_equal 2, attempt.attempt_number
    assert_equal({ 'message' => 'provider refused' }, attempt.error)
    # The generic selector prefers the historical success — the bug this guards.
    assert_equal 1, Tamoz::Agent::EffectDispatcher.send(:terminal_attempt, record).attempt_number
  end

  private

  def effect_attempt(number, status, result:, error:)
    Tamoz::Graph::EffectAttempt.new(
      identity: "attempt-#{number}", attempt_number: number, attempt_token: "tok-#{number}",
      fence: 1, status:, deadline_ms: 0, result:, external_id: nil, error:,
      prepared_at_ms: 0, started_at_ms: 0, completed_at_ms: number
    )
  end

  def effect_record(attempts, current_attempt:)
    Tamoz::Graph::EffectRecord.new(
      key: 'ek', logical_key: nil, thread_id: 't', namespace: [], execution_id: 'x',
      task_id: 'task', call_index: 0, operation: 'op', safety: :unsafe, status: :failed,
      request_digest: "sha256:#{'a' * 64}", current_attempt:, requires_reconciliation: false,
      attempts:, created_at_ms: 0, updated_at_ms: 0
    )
  end
end
