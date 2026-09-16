# frozen_string_literal: true

require_relative 'test_helper'

# The projection contract is intentionally asserted field-by-field.
# rubocop:disable Metrics/MethodLength, Minitest/MultipleAssertions
class AgentSessionStatusProjectionTest < Minitest::Test
  def test_projection_is_bounded_and_preserves_lifecycle_provenance
    event = {
      'event_type' => 'tool_result',
      'thread_id' => 'thread-1',
      'request_id' => 'request-1',
      'execution_id' => 'execution-1',
      'sequence' => 4,
      'phase' => 'action',
      'effect_state' => 'succeeded',
      'capability_id' => 'mcp:db/query',
      'output_bytes' => 128,
      'provenance' => 'p' * 1024,
      'truncated' => false
    }
    view = session_view(status: :paused, lifecycle_events: [event], interrupts: [{ 'kind' => 'approval' }])

    document = Tamoz::Agent::SessionStatusProjection.document(view, delivery_state: 'pending')
    lifecycle = Tamoz::Agent::SessionStatusProjection.lifecycle_events(view, delivery_state: 'pending').first

    assert_equal 'paused', document.fetch('task_state')
    assert_equal 'approval', document.fetch('next_action')
    assert_equal 'pending', document.fetch('delivery_state')
    assert_equal 'mcp:db/query', lifecycle.fetch('capability')
    assert_equal 512, lifecycle.fetch('result').fetch('provenance').bytesize
    refute lifecycle.key?('output')
  end

  # A cancellation commits a :completed checkpoint status, but the task did not
  # complete — the operator card must say stopped, not completed (F25-COR-01).
  def test_a_cancellation_terminal_projects_task_state_stopped
    view = session_view(
      status: :completed, lifecycle_events: [],
      terminal: { 'reason' => 'cancelled_by_user' }
    )

    document = Tamoz::Agent::SessionStatusProjection.document(view, delivery_state: 'pending')

    assert_equal 'stopped', document.fetch('task_state')
    assert_equal 'cancelled_by_user', document.fetch('terminal_reason')
  end

  def test_unknown_lifecycle_kind_is_rejected
    event = {
      'event_type' => 'model_output', 'thread_id' => 'thread-1', 'request_id' => 'request-1',
      'execution_id' => 'execution-1', 'sequence' => 1, 'phase' => 'plan', 'effect_state' => 'none'
    }

    assert_raises(Tamoz::CheckpointCorruptionError) do
      Tamoz::Agent::SessionStatusProjection.lifecycle_events(
        session_view(status: :running, lifecycle_events: [event])
      )
    end
  end

  private

  def session_view(status:, lifecycle_events:, interrupts: [], terminal: nil)
    Tamoz::Agent::SessionView.new(
      thread_id: 'thread-1', checkpoint_id: 'checkpoint-1', sequence: 4,
      execution_id: 'execution-1', request_id: 'request-1', status:, phase: :action,
      accepted_plan: nil, approvals: [], effect_receipts: [], blocked: false,
      terminal:, provider_ambiguity: nil, interrupts:, state: { lifecycle_events: }
    )
  end
end
# rubocop:enable Metrics/MethodLength, Minitest/MultipleAssertions
