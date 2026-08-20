# frozen_string_literal: true

require_relative 'test_helper'

# These tests pin the multi-field durable wire and its cross-boundary distinctions.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/MethodLength, Minitest/MultipleAssertions
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
    assert_equal "sha256:#{Digest::SHA256.hexdigest('o' * 2_000)}",
                 result.observations.fetch(0).fetch('output_digest')
    assert result.observations.fetch(0).fetch('output_unavailable')
    refute result.observations.fetch(0).key?('output_reference')
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

  def test_bounded_compactor_references_resolve_from_the_durable_artifact_store
    Dir.mktmpdir('tamoz-compaction-artifacts') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'tamoz.sqlite3'))
      store = adapter.bind_artifact_store(tenant: 'session.1')
      output = 'durable evidence\n' * 200

      result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new(
        artifact_store: store
      ).compact(
        context: {},
        observations: [{ 'output' => output, 'provenance' => 'workspace', 'truncated' => false }]
      )

      reference = result.observations.fetch(0).fetch('output_reference')
      resolved = store.resolve(reference.fetch('digest'))
      outcome = Data.define(:status, :value, :effect_key, :attempt_number).new(
        :unknown, nil, 'effect.compact.artifact', 1
      )
      effects = Object.new
      effects.define_singleton_method(:model_call) { |*| outcome }
      summarized = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new(
        artifact_store: store
      ).summarize(
        result, effects:, durable_context: Object.new, phase: :read_only, iteration: 0
      )

      assert_equal 'session.1', reference.fetch('tenant')
      assert_equal output, resolved.fetch('bytes')
      assert_equal reference.fetch('digest'), resolved.fetch('digest')
      assert_equal reference, summarized.record.fetch('artifact_refs').fetch(0)
    ensure
      adapter&.close
    end
  end

  def test_bounded_compactor_rejects_a_tenant_that_differs_from_the_store
    store = Object.new
    store.define_singleton_method(:tenant) { 'store.1' }

    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new(
        artifact_store: store, tenant: 'claimed.1'
      )
    end
  end

  def test_bounded_compactor_caps_many_individually_small_observations
    observations = Array.new(30) do |index|
      { 'step_id' => "step.#{index}", 'output' => 'o' * 900, 'provenance' => 'workspace' }
    end

    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.compact(
      context: {}, observations:
    )

    assert result.compacted
    assert_operator Tamoz::Core.jcs(result.observations).bytesize,
                    :<=, Tamoz::Agent::SessionPlanningContext::BoundedCompactor::MAX_OBSERVATIONS_BYTES
    assert(result.observations.any? { |observation| observation['output_unavailable'] })
  end

  def test_bounded_compactor_keeps_large_authoritative_history_within_the_hard_bound
    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.compact(
      context: { 'non_authoritative' => 'x' * 30_000 },
      observations: [],
      authoritative: {
        'goal' => 'preserve the goal',
        'plan_ids' => Array.new(500) { |index| "plan.#{index}" },
        'effect_ids' => Array.new(500) { |index| "effect.#{index}" },
        'approval_ids' => Array.new(500) { |index| "approval.#{index}" }
      }
    )

    assert_operator Tamoz::Core.jcs(result.context).bytesize,
                    :<=, Tamoz::Agent::SessionPlanningContext::BoundedCompactor::MAX_CONTEXT_BYTES
    assert_equal 'preserve the goal', result.context.fetch('authoritative').fetch('goal')
    assert result.context.fetch('authoritative').fetch('plan_ids').fetch('truncated')
    assert result.context.fetch('authoritative').fetch('effect_ids').fetch('truncated')
  end

  def test_compaction_summary_is_journaled_and_checkpoint_ready
    outcome = Data.define(:status, :value, :effect_key, :attempt_number).new(
      :succeeded, '{"summary":"Keep the goal and the pending effect."}', 'effect.compact.1', 1
    )
    calls = []
    effects = Object.new
    effects.define_singleton_method(:model_call) do |context, **arguments|
      calls << [context, arguments]
      outcome
    end
    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.compact(
      context: { 'non_authoritative' => 'x' * 30_000 },
      observations: [{ 'output' => 'o' * 2_000, 'provenance' => 'workspace' }],
      authoritative: { 'goal' => 'preserve this goal', 'next_action' => 'continue' }
    )

    summarized = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.summarize(
      result, effects:, durable_context: Object.new, phase: :read_only, iteration: 2
    )

    assert_equal 1, calls.length
    assert_equal :context_compact, calls.fetch(0).fetch(1).fetch(:stage)
    assert_equal 100, calls.fetch(0).fetch(1).fetch(:sub_operation)
    assert_equal 'Keep the goal and the pending effect.', summarized.context.fetch('summary').fetch('text')
    assert_equal 'model', summarized.record.fetch('mode')
    assert_equal 'effect.compact.1', summarized.record.fetch('effect_key')
    assert_equal summarized.record.fetch('summary_digest'),
                 Tamoz::Agent::SessionRecords.digest('summary' => summarized.record.fetch('summary'))
  end

  def test_compaction_unknown_summary_falls_back_without_fabricating_summary_evidence
    outcome = Data.define(:status, :value, :effect_key, :attempt_number).new(
      :unknown, nil, 'effect.compact.unknown', 1
    )
    effects = Object.new
    effects.define_singleton_method(:model_call) { |*| outcome }
    result = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.compact(
      context: { 'non_authoritative' => 'x' * 30_000 }, observations: []
    )

    summarized = Tamoz::Agent::SessionPlanningContext::BoundedCompactor.new.summarize(
      result, effects:, durable_context: Object.new, phase: :read_only, iteration: 0
    )

    assert_equal 'deterministic', summarized.record.fetch('mode')
    assert_equal 'fallback', summarized.record.fetch('status')
    assert_equal 'unknown', summarized.record.fetch('fallback_reason')
    assert_equal 'unknown', summarized.record.fetch('effect_status')
    refute summarized.record.key?('summary_digest')
    assert_equal 'Deterministic bounded context retained; model summary unavailable.',
                 summarized.record.fetch('summary')
    refute summarized.context.key?('summary')
  end

  def test_compaction_effect_receipt_reuses_after_adapter_restart
    Dir.mktmpdir('tamoz-compaction-restart') do |directory|
      path = File.join(directory, 'tamoz.sqlite3')
      thread_id = 'thread.compaction'
      request_id = 'request.compaction'
      first_model = Class.new do
        attr_reader :calls

        def initialize
          @calls = 0
        end

        def generate(**)
          @calls += 1
          'durable summary'
        end
      end.new
      second_model = first_model.class.new

      first_adapter = Tamoz::SQLite::Adapter.new(path:)
      definition = Tamoz.graph(name: 'compaction-restart', version: '1') do
        state :ready, default: false
        node(:finish, implementation_name: 'compaction.restart.finish', version: '1') { { ready: true } }
        edge Tamoz::START, :finish
        edge :finish, Tamoz::END
      end
      first_app = definition.compile(checkpointer: first_adapter)
      request = first_app.durable_runner.deliver(
        {}, thread: thread_id, request_id:
      )
      configuration = Struct.new(:model_call_safety, :model, :profile, :toolbox, :mcp).new(
        :idempotent, first_model, nil, Struct.new(:catalog_digest).new('catalog.1'), nil
      )
      run_compaction_effect(first_app.checkpointer, request.execution_id, first_model, configuration)
      first_adapter.close
      first_adapter = nil

      second_adapter = Tamoz::SQLite::Adapter.new(path:)
      second_app = definition.compile(checkpointer: second_adapter)
      configuration.model = second_model
      outcome = run_compaction_effect(second_app.checkpointer, request.execution_id, second_model, configuration)

      assert_equal :succeeded, outcome.status
      assert outcome.reused
      assert_equal 0, second_model.calls
      assert_equal 'durable summary', outcome.value
    ensure
      second_adapter&.close
      first_adapter&.close
    end
  end

  def run_compaction_effect(store, execution_id, model, configuration)
    outcome = nil
    store.open_writer(
      thread_id: 'thread.compaction', namespace: [], owner_id: "owner.#{model.object_id}", ttl: store.writer_ttl
    ) do |writer|
      context = Tamoz::Context.new(
        run_id: 'run.compaction', execution_id:, request_id: 'request.compaction',
        task_id: 'task.compaction', effects: writer.effects
      )
      outcome = Tamoz::Agent::SessionEffects.new(configuration:).model_call(
        context,
        stage: :context_compact,
        system: 'compact',
        prompt: '{"context":{}}',
        call_index: 0,
        iteration: 0,
        sub_operation: 100
      )
    end
    outcome
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/MethodLength, Minitest/MultipleAssertions
