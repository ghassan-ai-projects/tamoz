# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/approval_case'
require_relative 'support/comms_cli_fixture'
require_relative 'support/scripted_generation'

class TestFixtureHelpersTest < Minitest::Test
  include ApprovalCase
  include CommsCliFixture

  class ResponseModel < ScriptedGeneration::Model
  end

  def test_shared_generation_preserves_the_named_model_identity_used_by_effects
    model = ResponseModel.new(plan: ['response'])

    assert_equal 'TestFixtureHelpersTest::ResponseModel', model.class.name
  end

  def test_scripted_generation_consumes_the_prefix_and_repeats_the_final_response
    model = ResponseModel.new(plan: [{ 'answer' => 1 }, 'raw response'])

    responses = %w[first second third].map { |prompt| model.generate(stage: :plan, system: 'system', prompt:) }

    assert_equal ['{"answer":1}', 'raw response', 'raw response'], responses
    assert_equal(%w[first second third], model.calls.map { |call| call.fetch(:prompt) })
  end

  def test_scripted_generation_rejects_an_empty_response_queue_and_records_the_attempt
    model = ResponseModel.new(plan: [])
    error = assert_raises(RuntimeError) { model.generate(stage: :plan, system: 'system', prompt: 'first') }

    assert_equal 'no scripted plan response', error.message
    assert_equal [{ stage: :plan, system: 'system', prompt: 'first' }], model.calls
  end

  def test_scripted_generation_rejects_an_unconfigured_stage
    model = ResponseModel.new(plan: ['response'])

    assert_raises(KeyError) { model.generate(stage: :verify, system: 'system', prompt: 'first') }
  end

  def test_models_consume_separate_queues_without_changing_the_supplied_responses
    [ScriptedGeneration::Model, ScriptedGeneration::QueueModel].each do |model_class|
      responses = { plan: %w[first second], review: [], verify: [] }
      first = model_class.new(**responses)
      second = model_class.new(**responses)

      outputs = [first.generate(stage: :plan, system: 'system', prompt: 'one'),
                 first.generate(stage: :plan, system: 'system', prompt: 'two'),
                 second.generate(stage: :plan, system: 'system', prompt: 'one')]

      assert_equal %w[first second first], outputs
      assert_equal %w[first second], responses.fetch(:plan)
    end
  end

  def test_queued_generation_rejects_exhaustion_instead_of_repeating_a_response
    model = ScriptedGeneration::QueueModel.new(plan: [{ 'answer' => 1 }], review: [], verify: [])

    assert_equal '{"answer":1}', model.generate(stage: :plan, system: 'system', prompt: 'one')
    error = assert_raises(RuntimeError) { model.generate(stage: :plan, system: 'system', prompt: 'two') }

    assert_equal ['missing plan response', %w[one two]],
                 [error.message, model.calls.map { |call| call.fetch(:prompt) }]
  end

  def test_queued_generation_rejects_an_unconfigured_stage
    model = ScriptedGeneration::QueueModel.new(plan: [], review: [], verify: [])

    assert_raises(KeyError) { model.generate(stage: :unexpected, system: 'system', prompt: 'one') }
  end

  def test_policy_fixture_flushes_content_and_removes_the_file_after_returning
    path, content = with_policy("version: 1\n") { |file| [file, File.read(file)] }

    assert_equal "version: 1\n", content
    refute_path_exists path
  end

  def test_policy_fixture_removes_the_file_when_the_block_raises
    path = nil
    failure = RuntimeError.new('block failed')
    raised = assert_raises(RuntimeError) do
      with_policy('version: 1') do |file|
        path = file
        raise failure
      end
    end

    assert_same failure, raised
    refute_path_exists path
  end

  def test_store_fixture_closes_the_store_after_returning_the_block_result
    Dir.mktmpdir('comms-fixture') do |directory|
      store = nil
      result = with_store(Data.define(:dir).new(directory)) do |bound_store|
        store = bound_store
        :result
      end

      assert_equal :result, result
      assert_raises(Tamoz::SQLite::ClosedError) { store.admission_audit_counts }
    end
  end

  def test_store_fixture_closes_the_store_when_the_block_raises
    Dir.mktmpdir('comms-fixture') do |directory|
      store = nil
      failure = RuntimeError.new('block failed')
      raised = assert_raises(RuntimeError) do
        with_store(Data.define(:dir).new(directory)) do |bound_store|
          store = bound_store
          raise failure
        end
      end

      assert_same failure, raised
      assert_raises(Tamoz::SQLite::ClosedError) { store.admission_audit_counts }
    end
  end
end
