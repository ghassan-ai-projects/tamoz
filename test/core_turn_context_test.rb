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

  # A chat reply is often longer than a fragment and multi-byte (Arabic, emoji, dashes); the next
  # message must still be admitted, with the history clipped rather than the turn refused.
  def test_long_multibyte_history_is_clipped_to_the_bounds_instead_of_refused
    reply = "مرحبا — #{'نعم ' * 200}✅\nnext line"
    fragments = Array.new(14) { |index| { 'role' => index.even? ? 'user' : 'assistant', 'text' => reply } }

    task = Tamoz::Core::TurnContext.task(thread_id: 't', request_id: 'r', text: 'x' * 6_000, fragments:)
                                   .fetch('task')
    kept = Tamoz::Core::TurnContext.fragments_from(task.fetch('context'), thread_id: 't', request_id: 'r')

    refute_empty kept
    assert(kept.all? { |fragment| fragment['text'].bytesize <= 500 && fragment['text'].valid_encoding? })
    assert_operator Tamoz::Core.jcs(task).bytesize, :<=, Tamoz::Core::TurnContext::MAX_CONTEXT_BYTES
  end
end
