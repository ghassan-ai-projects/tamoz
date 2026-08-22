# frozen_string_literal: true

require_relative 'test_helper'

class CoreTurnContextTest < Minitest::Test
  def test_context_round_trips_with_bound_identity_and_digest
    payload = Tamoz::Core::TurnContext.task(
      thread_id: 'thread-1',
      request_id: 'request-1',
      text: 'continue',
      fragments: [
        { 'role' => 'user', 'text' => 'make it blue' },
        { 'role' => 'assistant', 'text' => 'I will update the design' }
      ]
    )

    task = payload.fetch('task')

    assert_equal 'continue', task.fetch('text')
    assert_equal(
      [
        { 'role' => 'user', 'text' => 'make it blue' },
        { 'role' => 'assistant', 'text' => 'I will update the design' }
      ],
      Tamoz::Core::TurnContext.fragments_from(
        task.fetch('context'), thread_id: 'thread-1', request_id: 'request-1'
      )
    )
  end

  def test_empty_context_keeps_scalar_task_shape
    assert_equal(
      { 'task' => 'first turn' },
      Tamoz::Core::TurnContext.task(
        thread_id: 'thread-1', request_id: 'request-1', text: 'first turn', fragments: []
      )
    )
  end

  def test_tampered_context_is_rejected
    payload = Tamoz::Core::TurnContext.task(
      thread_id: 'thread-1', request_id: 'request-1', text: 'continue',
      fragments: [{ 'role' => 'user', 'text' => 'make it blue' }]
    )
    context = payload.fetch('task').fetch('context').merge('fragments' => [])

    assert_raises(Tamoz::CheckpointCorruptionError) do
      Tamoz::Core::TurnContext.fragments_from(context, thread_id: 'thread-1', request_id: 'request-1')
    end
  end
end
