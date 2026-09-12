# frozen_string_literal: true

require_relative 'test_helper'

# Phase 2 of the model-call boundary implementation: the ephemeral one-shot
# runtime crosses EffectDispatcher like every durable consumer, over an
# in-memory journal whose receipts live and die with the turn.
class AgentRuntimeEffectsTest < Minitest::Test
  def test_same_logical_identity_replays_the_recorded_receipt_without_recalling
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    calls = 0

    first = dispatch(journal, 't1') do
      calls += 1
      'answer'
    end
    second = dispatch(journal, 't1') do
      calls += 1
      'different answer'
    end

    assert_equal :succeeded, first.status
    refute first.reused
    assert_equal :succeeded, second.status
    assert second.reused
    assert_equal 'answer', second.value
    assert_equal 1, calls
  end

  def test_distinct_identity_executes_fresh
    journal = Tamoz::Agent::Runtime::EffectsJournal.new

    first = dispatch(journal, 'a') { 'one' }
    second = dispatch(journal, 'b') { 'two' }

    refute first.reused
    refute second.reused
    assert_equal 'one', first.value
    assert_equal 'two', second.value
  end

  def test_typed_failure_replays_as_failed_and_never_retries_automatically
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    dispatch(journal, 'f1') { raise Tamoz::Tools::ToolError, 'provider refused' }
    calls = 0

    outcome = dispatch(journal, 'f1') do
      calls += 1
      'nope'
    end

    assert_equal :failed, outcome.status
    assert_equal 0, calls
  end

  def test_unknown_receipt_replays_as_unknown_after_attempt_budget_exhaustion
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    3.times { prepare_call(journal) }

    exhausted = prepare_call(journal)
    replayed = prepare_call(journal)

    assert_equal :unknown, exhausted.action
    assert_equal :unknown, replayed.action
    assert_equal :unknown, dispatch(journal, 'frozen', logical_key: journal.logical_key('shared-call')).status
  end

  def test_journal_binds_requests_and_fences_terminal_receipts
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    decision = prepare_call(journal)

    assert_raises(Tamoz::CheckpointConflictError) do
      journal.start(key: decision.record.key, attempt_token: nil)
    end
    assert_raises(Tamoz::CheckpointConflictError) do
      journal.complete(
        key: decision.record.key, attempt_token: 'wrong-token', status: :succeeded, result: 'bad'
      )
    end

    journal.start(key: decision.record.key, attempt_token: decision.attempt_token)
    completed = journal.complete(
      key: decision.record.key, attempt_token: decision.attempt_token,
      status: :succeeded, result: 'answer'
    )

    assert_equal completed, journal.complete(
      key: decision.record.key, attempt_token: decision.attempt_token,
      status: :succeeded, result: 'answer'
    )
    assert_raises(Tamoz::CheckpointConflictError) do
      journal.complete(
        key: decision.record.key, attempt_token: decision.attempt_token,
        status: :succeeded, result: 'different'
      )
    end
    assert_raises(Tamoz::CheckpointConflictError) do
      prepare_call(journal, request: { 'stage' => 'changed' })
    end
  end

  def test_a_typed_model_failure_keeps_its_class_and_message
    Dir.mktmpdir('tamoz-agent') do |root|
      model = Class.new do
        def generate(stage:, system:, prompt:)
          @calls ||= []
          @calls << { stage:, system:, prompt: }
          raise Tamoz::Core::ToolError, 'boom' if stage == :plan

          stage.to_s
        end
      end.new

      runtime = Tamoz::Agent.build(model:, root:)

      error = assert_raises(Tamoz::Core::ToolError) { runtime.run('read note.txt') }
      assert_equal 'boom', error.message
    end
  end

  def test_a_replayed_model_failure_keeps_the_model_error_class
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    error = Tamoz::Agent::ModelCallError.new(
      code: 'http_failure', status: 503,
      body_digest: "sha256:#{'d' * 64}", body_bytes: 19
    )
    first = dispatch(journal, 'model-failure') { raise error }
    second = dispatch(journal, 'model-failure') { flunk 'replayed model failure called the model' }
    Dir.mktmpdir('tamoz-agent') do |root|
      runtime = Tamoz::Agent.build(
        model: Class.new { def generate(**) = 'unused' }.new, root:
      )

      assert_equal :failed, first.status
      assert_equal :failed, second.status
      replayed = runtime.send(:journaled_model_failure, second)
      assert_instance_of Tamoz::Agent::ModelCallError, replayed
      assert_equal error.message, replayed.message
      assert_equal error.code, replayed.code
      assert_equal error.status, replayed.status
      assert_equal error.body_digest, replayed.body_digest
      assert_equal error.body_bytes, replayed.body_bytes
    end
  end

  def test_runtime_preserves_an_unknown_model_outcome
    Dir.mktmpdir('tamoz-agent') do |root|
      model = Class.new do
        def generate(**)
          raise Tamoz::EffectUnknownError, 'provider outcome is unknown'
        end
      end.new
      runtime = Tamoz::Agent.build(model:, root:)

      runtime.send(:start_turn)
      error = assert_raises(Tamoz::EffectUnknownError) do
        runtime.send(:model_generate, stage: :plan, system: 'system', prompt: 'prompt')
      end

      assert_equal 'provider outcome is unknown', error.message
      assert_equal :unknown, runtime.effects.instance_variable_get(:@records).values.last.status
    end
  end

  def test_a_journaled_runtime_turn_records_every_model_call
    Dir.mktmpdir('tamoz-agent') do |root|
      File.write(File.join(root, 'note.txt'), "Tamoz is awake.\n")
      model = scripted_read_only_model(root)
      runtime = Tamoz::Agent.build(model:, root:)

      result = runtime.run('What does note.txt say?')

      assert result.satisfied
      operations = recorded_operations(runtime.effects)

      assert_equal(
        %w[model.generate.plan model.generate.review model.generate.verify],
        operations.map { |op| op.fetch('operation') }.uniq
      )
      operations.each do |row|
        assert_equal 'succeeded', row.fetch('status')
        assert row.fetch('effect_key').start_with?('logical:')
      end
    end
  end

  def test_runtime_call_ordinal_and_turn_identity_keep_same_stage_calls_distinct
    Dir.mktmpdir('tamoz-agent') do |root|
      model = Class.new do
        def generate(stage:, system:, prompt:)
          'answer'
        end
      end.new
      runtime = Tamoz::Agent.build(model:, root:)

      runtime.send(:start_turn)
      2.times do
        runtime.send(:model_generate, stage: :plan, system: 'system', prompt: 'prompt')
      end
      first_turn_keys = recorded_keys(runtime.effects)

      runtime.send(:start_turn)
      runtime.send(:model_generate, stage: :plan, system: 'system', prompt: 'prompt')
      all_keys = recorded_keys(runtime.effects)

      assert_equal 2, first_turn_keys.uniq.length
      assert_equal 3, all_keys.uniq.length
      refute_equal first_turn_keys.first, all_keys.last
    end
  end

  private

  def dispatch(journal, identity_suffix, logical_key: nil, &)
    context = Tamoz::Agent::Runtime::EffectContext.new(
      effects: journal,
      execution_id: 'exec-1',
      task_id: 'task-1',
      request_id: 'req-1'
    )
    options = {
      context:,
      operation: 'model.generate.plan',
      safety: :idempotent,
      call_index: 1,
      request: { 'stage' => 'plan' },
      actor: 'test'
    }
    unless logical_key
      options[:logical_identity] = {
        operation: 'model.generate.plan',
        capability_id: 'model:plan',
        arguments: { 'nonce' => identity_suffix },
        authority_revision: "sha256:#{'a' * 64}",
        catalog_revision: "sha256:#{'b' * 64}",
        iteration: 1,
        sub_operation: 0
      }
    end
    options[:logical_key] = logical_key if logical_key
    Tamoz::Agent::EffectDispatcher.run(**options, &)
  end

  def prepare_call(journal, request: { 'stage' => 'plan' })
    journal.prepare(
      execution_id: 'exec-1', task_id: 'task-1', call_index: 1,
      operation: 'model.generate.plan', safety: 'idempotent', request:,
      logical_key: journal.logical_key('shared-call')
    )
  end

  def scripted_read_only_model(root)
    Class.new do
      def initialize(root)
        @root = root
      end

      attr_reader :calls

      def generate(stage:, system:, prompt:)
        @calls ||= []
        @calls << { stage:, system:, prompt: }
        case stage
        when :plan
          JSON.generate(
            'goal' => 'read the note',
            'done_when' => ['output present'],
            'steps' => [{
              'id' => 's1', 'purpose' => 'read',
              'tool' => 'read_file',
              'arguments' => { 'path' => 'note.txt' },
              'verification' => 'output present'
            }]
          )
        when :review
          JSON.generate('decision' => 'accept', 'issues' => [], 'rationale' => 'sound')
        else
          JSON.generate('answer' => 'Tamoz is awake.', 'satisfied' => true,
                        'evidence' => ['note.txt'])
        end
      end
    end.new(root)
  end

  def recorded_operations(journal)
    journal.instance_variable_get(:@records).values.map do |record|
      {
        'operation' => record.operation,
        'status' => record.attempts.last.status.to_s,
        'effect_key' => record.key
      }
    end
  end

  def recorded_keys(journal)
    journal.instance_variable_get(:@records).values.map(&:key)
  end
end
