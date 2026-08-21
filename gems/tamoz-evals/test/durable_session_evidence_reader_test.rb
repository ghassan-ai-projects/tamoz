# frozen_string_literal: true

require_relative '../../../test/test_helper'

# rubocop:disable Minitest/MultipleAssertions -- the reader contract has multiple joined fields.
# The reader must join view state with durable journal records without advancing the session.
class DurableSessionEvidenceReaderTest < Minitest::Test
  THREAD = 'openclaw.reader-test'

  def test_reads_succeeded_model_receipts_from_the_journal_and_keeps_view_receipts
    with_fake_runtime do |reader|
      evidence = reader.call(runtime_dir: @runtime_dir, thread: THREAD, provider: 'openai', model: 'test')

      assert_equal(
        %w[tool.mcp:alms/health.check model.generate.adaptive_decide],
        evidence.fetch('effect_receipts').map { |receipt| receipt.fetch('operation') }
      )
      assert_equal(
        { 'input_tokens' => 12, 'output_tokens' => 7 },
        evidence.dig('effect_receipts', 1, 'usage')
      )
      assert evidence.fetch('effect_receipts_complete')
      assert_equal 'read_only', evidence.dig('effect_receipts', 0, 'safety')
      assert_equal 'idempotent', evidence.dig('effect_receipts', 1, 'safety')
      assert_equal ['observation:0'], evidence.fetch('observation_refs')
    end
  end

  private

  def with_fake_runtime
    Dir.mktmpdir('evidence-reader') do |runtime_dir|
      Tamoz::Agent::RuntimeDirectory.create!(runtime_dir, workspace: runtime_dir)
      @runtime_dir = runtime_dir
      runtime = fake_runtime
      original_open = Tamoz::Agent::WorkerRuntime.method(:open)
      Tamoz::Agent::WorkerRuntime.define_singleton_method(:open) { |_directory, **_kwargs| runtime }
      yield Tamoz::Evals::Benchmark::DurableSessionEvidenceReader.new(env: {})
    ensure
      Tamoz::Agent::WorkerRuntime.define_singleton_method(:open, original_open)
      @runtime_dir = nil
    end
  end

  def fake_runtime
    view = Struct.new(:status, :terminal, :effect_receipts, :state).new(
      :completed,
      { 'satisfied' => true },
      [{ 'effect_key' => 'tool-key', 'operation' => 'tool.mcp:alms/health.check', 'status' => 'succeeded' }],
      view_state
    )
    state_codec = Tamoz::StateCodec.new
    result_bytes, result_digest = journal_result(state_codec)
    checkpoints = fake_checkpoints(state_codec)
    adapter = fake_adapter(result_bytes, result_digest)
    session = fake_session(view)
    runtime = Object.new
    runtime.define_singleton_method(:session_for) do |thread|
      raise 'wrong thread' unless thread == THREAD

      session
    end
    runtime.define_singleton_method(:checkpoints) { checkpoints }
    runtime.define_singleton_method(:adapter) { adapter }
    runtime.define_singleton_method(:close) { nil }
    runtime
  end

  def fake_checkpoints(state_codec)
    checkpoints = Object.new
    checkpoint_codec = Struct.new(:state_codec).new(state_codec)
    checkpoints.define_singleton_method(:checkpoint_codec) { checkpoint_codec }
    checkpoints.define_singleton_method(:effect_census) do |limit:|
      raise 'wrong limit' unless limit == 10_000

      [
        {
          effect_key: 'tool-key', thread_id: THREAD, operation: 'tool.mcp:alms/health.check',
          safety: :read_only, status: :succeeded
        },
        {
          effect_key: 'model-key', thread_id: THREAD, operation: 'model.generate.adaptive_decide',
          safety: :idempotent, status: :succeeded
        }
      ]
    end
    checkpoints
  end

  def view_state
    {
      verification: { 'configured_check_passed' => true },
      observations: [{ 'evidence_ref' => 'observation:0' }]
    }
  end

  def fake_adapter(result_bytes, result_digest)
    transaction = Object.new
    transaction.define_singleton_method(:rows) do |*_arguments|
      [['model-key', 'model.generate.adaptive_decide', 'succeeded', result_bytes, result_digest]]
    end
    adapter = Object.new
    adapter.define_singleton_method(:read) do |operation:, &block|
      raise 'wrong operation' unless operation == 'benchmark.model_receipts'

      block.call(transaction)
    end
    adapter
  end

  def journal_result(state_codec)
    result = { 'usage' => { 'input_tokens' => 12, 'output_tokens' => 7 } }
    bytes = state_codec.dump(result)
    digest = Tamoz::SQLite.const_get(:Wire, false).digest(
      bytes, domain: 'tamoz.sqlite.effect_result'
    )
    [bytes, digest]
  end

  def fake_session(view)
    session = Object.new
    session.define_singleton_method(:view) do |thread:|
      raise 'wrong thread' unless thread == THREAD

      view
    end
    session
  end
end
# rubocop:enable Minitest/MultipleAssertions
