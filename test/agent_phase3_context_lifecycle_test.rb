# frozen_string_literal: true

require_relative 'test_helper'

# These tests pin the multi-field durable wire and its cross-boundary distinctions.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
class AgentPhase3ContextLifecycleTest < Minitest::Test
  Request = Data.define(:request_id, :operation, :payload)

  def test_follow_up_payload_seals_identity_order_and_digest
    payload = Tamoz::Agent::SessionPlanningContext.turn_payload(
      thread_id: 'thread.1', request_id: 'request.2', text: 'and the font?',
      fragments: [
        { 'role' => 'user', 'text' => 'make it blue' },
        { 'role' => 'assistant', 'text' => 'done, it is blue' }
      ]
    )
    context = payload.fetch('task').fetch('context')

    assert_equal %w[thread.1 request.2], [context.fetch('thread_id'), context.fetch('request_id')]
    assert_equal [
      { 'role' => 'user', 'text' => 'make it blue' },
      { 'role' => 'assistant', 'text' => 'done, it is blue' }
    ], context.fetch('fragments')
    unsigned_context = context.dup
    unsigned_context.delete('digest')

    assert_equal Tamoz::Core::TurnContext.digest(unsigned_context), context.fetch('digest')
    refute context.key?('authority')
    refute context.key?('capability')
  end

  def test_transcript_readback_rejects_a_mutated_context
    payload = Tamoz::Agent::SessionPlanningContext.turn_payload(
      thread_id: 'thread.1', request_id: 'request.2', text: 'follow up',
      fragments: [{ 'role' => 'user', 'text' => 'earlier' }]
    )
    request = Request.new('request.2', :turn, payload)
    reader = Object.new
    reader.define_singleton_method(:fetch_request) { |**| request }

    assert_equal [{ 'role' => 'user', 'text' => 'earlier' }],
                 Tamoz::Agent::SessionPlanningContext.transcript_from(
                   reader, thread_id: 'thread.1', request_id: 'request.2'
                 )

    request.payload.fetch('task').fetch('context')['fragments'][0]['text'] = 'tampered'
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Tamoz::Agent::SessionPlanningContext.transcript_from(
        reader, thread_id: 'thread.1', request_id: 'request.2'
      )
    end
  end

  def test_cli_follow_up_uses_prior_durable_turns_as_fragments
    first = Request.new('request.1', :turn, { 'task' => 'first task' })
    second = Request.new(
      'request.2', :turn,
      Tamoz::Agent::SessionPlanningContext.turn_payload(
        thread_id: 'thread.1', request_id: 'request.2', text: 'second task',
        fragments: [{ 'role' => 'user', 'text' => 'first task' }]
      )
    )
    reader = Object.new
    reader.define_singleton_method(:request_history) { |**| [first, second] }

    payload = Tamoz::Agent::SessionPlanningContext.follow_up_payload(
      reader, thread_id: 'thread.1', request_id: 'request.3', text: 'third task'
    )

    assert_equal [
      { 'role' => 'user', 'text' => 'first task' },
      { 'role' => 'user', 'text' => 'second task' }
    ], payload.fetch('task').fetch('context').fetch('fragments')
  end

  def test_status_projection_keeps_task_effect_capability_and_delivery_distinct
    event = Tamoz::Agent::SessionRecords.build(
      'lifecycle_event',
      event_type: 'tool_result', sequence: 0, request_id: 'request.1',
      thread_id: 'thread.1', execution_id: 'execution.1', phase: 'adaptive_read_only',
      effect_state: 'unknown', delivery_state: 'pending', iteration: 1,
      capability_id: 'local.read_file', source_id: 'workspace', provenance: 'workspace',
      truncated: true, output_bytes: 500
    )
    view = Tamoz::Agent::SessionView.new(
      thread_id: 'thread.1', checkpoint_id: 'checkpoint.1', sequence: 2,
      execution_id: 'execution.1', request_id: 'request.1', status: :blocked,
      phase: 'adaptive_read_only', accepted_plan: nil, approvals: [], effect_receipts: [],
      blocked: { 'reason' => 'effect_unknown' }, terminal: nil, provider_ambiguity: 0,
      interrupts: [], state: { lifecycle_events: [event] }
    )

    document = Tamoz::Agent::SessionStatusProjection.document(view, delivery_state: 'pending')

    assert_equal 'blocked', document.fetch('task_state')
    assert_equal 'unknown', document.fetch('effect_state')
    assert_equal 'invoked', document.fetch('capability_state')
    assert_equal 'pending', document.fetch('delivery_state')

    projected = Tamoz::Agent::SessionStatusProjection.lifecycle_events(view, delivery_state: 'pending')

    assert_equal 'tool_result', projected.fetch(0).fetch('kind')
    assert_equal 500, projected.fetch(0).fetch('result').fetch('bytes')
    refute projected.fetch(0).fetch('result').key?('output')
  end

  def test_bounded_compactor_preserves_authority_and_bounds_large_observations
    context = {
      'non_authoritative' => 'x' * 30_000,
      'goal' => 'ship the task'
    }
    observation = {
      'step_id' => 'step.1', 'effect_key' => 'effect.1', 'provenance' => 'workspace',
      'truncated' => false, 'output' => 'o' * 2_000
    }

    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.compact(
      context:,
      observations: [observation],
      authoritative: {
        'goal' => 'ship the task', 'plan_ids' => ['plan.1'],
        'effect_ids' => ['effect.1'], 'approval_ids' => ['approval.1'],
        'next_action' => 'continue'
      }
    )

    assert result.compacted
    assert_operator Tamoz::Core.jcs(result.context).bytesize,
                    :<=, Tamoz::Agent::SessionPlanningContext::BoundedCompactor::MAX_CONTEXT_BYTES
    assert_equal 'ship the task', result.context.fetch('authoritative').fetch('goal')
    assert_equal ['plan.1'], result.context.fetch('authoritative').fetch('plan_ids')
    assert_equal ['effect.1'], result.context.fetch('authoritative').fetch('effect_ids')
    assert_equal ['approval.1'], result.context.fetch('authoritative').fetch('approval_ids')
    assert_equal 'continue', result.context.fetch('authoritative').fetch('next_action')
    assert_equal 2_000, result.observations.fetch(0).fetch('output_reference').fetch('byte_count')
    assert_equal "sha256:#{Digest::SHA256.hexdigest('o' * 2_000)}",
                 result.observations.fetch(0).fetch('output_reference').fetch('digest')
  end

  def test_bounded_compactor_retains_large_observation_only_through_supplied_store
    retained = []
    store = Object.new
    store.define_singleton_method(:tenant) { 'tenant.1' }
    store.define_singleton_method(:retain) { |**entry| retained << entry }
    output = 'o' * 2_000

    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new(artifact_store: store).compact(
      context: {}, observations: [{ 'output' => output, 'provenance' => 'remote_untrusted', 'truncated' => true }]
    )

    assert_equal 1, retained.length
    assert_equal 'tenant.1', result.observations.fetch(0).fetch('output_reference').fetch('tenant')
    assert_equal output, retained.fetch(0).fetch(:bytes)
    assert_equal 'text/plain', retained.fetch(0).fetch(:media_type)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
