# frozen_string_literal: true

require_relative 'test_helper'

class AgentRuntimeEffectsTest < Minitest::Test
  class ScriptedReadOnlyModel
    attr_reader :calls

    def initialize(root)
      @root = root
    end

    def generate(stage:, system:, prompt:)
      @calls ||= []
      @calls << { stage:, system:, prompt: }
      case stage
      when :plan then plan_json
      when :review then JSON.generate('decision' => 'accept', 'issues' => [], 'rationale' => 'sound')
      else
        JSON.generate('answer' => 'Tamoz is awake.', 'satisfied' => true, 'evidence' => ['note.txt'])
      end
    end

    private

    def plan_json
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
    end
  end

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

    assert_equal [[:succeeded, false], [:succeeded, true], 'answer', 1],
                 [[first.status, first.reused], [second.status, second.reused], second.value, calls]
  end

  def test_distinct_identity_executes_fresh
    journal = Tamoz::Agent::Runtime::EffectsJournal.new

    first = dispatch(journal, 'a') { 'one' }
    second = dispatch(journal, 'b') { 'two' }

    assert_equal [[false, 'one'], [false, 'two']],
                 [[first.reused, first.value], [second.reused, second.value]]
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

  def test_journal_rejects_a_missing_or_wrong_attempt_token
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
  end

  def test_journal_binds_requests_and_fences_terminal_receipts
    journal = Tamoz::Agent::Runtime::EffectsJournal.new
    decision = prepare_call(journal)
    journal.start(key: decision.record.key, attempt_token: decision.attempt_token)
    completed = complete_call(journal, decision, 'answer')

    assert_equal completed, complete_call(journal, decision, 'answer')
    assert_raises(Tamoz::CheckpointConflictError) { complete_call(journal, decision, 'different') }
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
    replayed = replay_model_failure(second)

    assert_instance_of Tamoz::Agent::ModelCallError, replayed
    assert_equal [%i[failed failed], model_error_fields(error)],
                 [[first.status, second.status], model_error_fields(replayed)]
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
      assert_equal :unknown, runtime.effects.records.last.status
    end
  end

  def test_a_journaled_runtime_turn_records_every_model_call
    Dir.mktmpdir('tamoz-agent') do |root|
      File.write(File.join(root, 'note.txt'), "Tamoz is awake.\n")
      model = scripted_read_only_model(root)
      runtime = Tamoz::Agent.build(model:, root:)

      result = runtime.run('What does note.txt say?')
      operations = recorded_operations(runtime.effects)

      assert result.satisfied
      assert_equal(
        %w[model.generate.plan model.generate.review model.generate.verify],
        operations.map { |op| op.fetch('operation') }.uniq
      )
      assert_equal [['succeeded', true]], operations.map { |row| status_and_logical_key(row) }.uniq
    end
  end

  def test_runtime_call_ordinal_and_turn_identity_keep_same_stage_calls_distinct
    Dir.mktmpdir('tamoz-agent') do |root|
      model = Class.new do
        def generate(**) = 'answer'
      end.new
      runtime = Tamoz::Agent.build(model:, root:)

      first_turn_keys = run_plan_calls(runtime, 2)
      all_keys = run_plan_calls(runtime, 1)

      assert_equal 2, first_turn_keys.uniq.length
      assert_equal 3, all_keys.uniq.length
      refute_equal first_turn_keys.first, all_keys.last
    end
  end

  private

  def dispatch(journal, identity_suffix, logical_key: nil, &)
    options = {
      context: effect_context(journal),
      operation: 'model.generate.plan',
      safety: :idempotent,
      call_index: 1,
      request: { 'stage' => 'plan' },
      actor: 'test'
    }
    if logical_key
      options[:logical_key] = logical_key
    else
      options[:logical_identity] = logical_identity(identity_suffix)
    end
    Tamoz::Agent::EffectDispatcher.run(**options, &)
  end

  def effect_context(journal)
    Tamoz::Agent::Runtime::EffectContext.new(
      effects: journal,
      execution_id: 'exec-1',
      task_id: 'task-1',
      request_id: 'req-1'
    )
  end

  def logical_identity(identity_suffix)
    {
      operation: 'model.generate.plan',
      capability_id: 'model:plan',
      arguments: { 'nonce' => identity_suffix },
      authority_revision: "sha256:#{'a' * 64}",
      catalog_revision: "sha256:#{'b' * 64}",
      iteration: 1,
      sub_operation: 0
    }
  end

  def prepare_call(journal, request: { 'stage' => 'plan' })
    journal.prepare(
      execution_id: 'exec-1', task_id: 'task-1', call_index: 1,
      operation: 'model.generate.plan', safety: 'idempotent', request:,
      logical_key: journal.logical_key('shared-call')
    )
  end

  def complete_call(journal, decision, result)
    journal.complete(
      key: decision.record.key, attempt_token: decision.attempt_token,
      status: :succeeded, result:
    )
  end

  def replay_model_failure(outcome)
    Dir.mktmpdir('tamoz-agent') do |root|
      runtime = Tamoz::Agent.build(model: Class.new { def generate(**) = 'unused' }.new, root:)
      runtime.send(:journaled_model_failure, outcome)
    end
  end

  def model_error_fields(error)
    {
      message: error.message, code: error.code, status: error.status,
      body_digest: error.body_digest, body_bytes: error.body_bytes
    }
  end

  def run_plan_calls(runtime, count)
    runtime.send(:start_turn)
    count.times { runtime.send(:model_generate, stage: :plan, system: 'system', prompt: 'prompt') }
    recorded_keys(runtime.effects)
  end

  def status_and_logical_key(row)
    [row.fetch('status'), row.fetch('effect_key').start_with?('logical:')]
  end

  def scripted_read_only_model(root)
    ScriptedReadOnlyModel.new(root)
  end

  def recorded_operations(journal)
    journal.records.map do |record|
      {
        'operation' => record.operation,
        'status' => record.attempts.last.status.to_s,
        'effect_key' => record.key
      }
    end
  end

  def recorded_keys(journal)
    journal.records.map(&:key)
  end
end
