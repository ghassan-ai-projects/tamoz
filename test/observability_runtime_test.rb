# frozen_string_literal: true

require_relative 'test_helper'

class ObservabilityRuntimeTest < Minitest::Test
  Observability = Tamoz::Observability

  def test_default_policy_emits_digest_and_size_without_content
    recorder = Observability::Recorder::Memory.new
    producer = Observability::Producer.new(recorder:)

    assert_equal :recorded, producer.emit(
      'tamoz.worker.error',
      attributes: {reason: 'failure'},
      content: {error_detail: 'private prompt'}
    )

    document = recorder.signals.first.to_h
    assert_equal({'error_detail_digest' => document.fetch('content').fetch('error_detail_digest'),
                  'error_detail_bytes' => 14}, document.fetch('content'))
    refute_includes JSON.generate(document), 'private prompt'
    assert_equal Observability::ContentPolicy::NONE.digest, document.fetch('policy_digest')
  end

  def test_secret_is_rejected_before_it_can_reach_a_signal
    recorder = Observability::Recorder::Memory.new
    producer = Observability::Producer.new(recorder:)

    assert_equal :dropped, producer.emit(
      'tamoz.worker.error',
      content: {error_detail: {'credential' => Tamoz::Secret.new('secret')}}
    )
    assert_empty recorder.signals
  end

  def test_restricted_policy_refuses_capture_at_load
    assert_raises(Observability::ValidationError) do
      Observability::ContentPolicy.new(
        name: 'restricted-debug',
        max_classification: :restricted,
        tool_results: {enabled: true, max_bytes: 100}
      )
    end
  end

  def test_enabled_content_is_bounded_and_policy_is_recorded
    policy = Observability::ContentPolicy.new(
      name: 'tool-debug',
      error_detail: {enabled: true, max_bytes: 5}
    )
    recorder = Observability::Recorder::Memory.new(policy_digest: policy.digest)
    producer = Observability::Producer.new(recorder:, policy:)

    assert_equal :recorded, producer.emit(
      'tamoz.worker.error',
      content: {error_detail: 'abcdef'}
    )
    document = recorder.signals.first.to_h
    assert_equal 'abcde', document.fetch('content').fetch('error_detail')
    assert document.fetch('content').fetch('error_detail_truncated')
    assert_equal policy.digest, document.fetch('policy_digest')
  end

  def test_journal_rotates_and_preserves_private_permissions
    Dir.mktmpdir do |directory|
      journal = Observability::Recorder::Journal.new(
        directory:, role: 'worker', queue_size: 4, max_file_bytes: 220, max_files: 2
      )
      producer = Observability::Producer.new(recorder: journal)
      12.times { producer.emit('tamoz.worker.error', attributes: {reason: 'x' * 20}) }
      assert_equal 0, journal.flush(deadline_ms: 1_000)
      journal.close

      inventory = Observability::Recorder::Journal.inventory(directory)
      assert_operator inventory.fetch('files'), :>, 1
      assert_equal 0o700, File.stat(directory).mode & 0o777
      assert_operator File.stat(Dir.glob(File.join(directory, '*.ndjson')).first).mode & 0o777, :<=, 0o600
      assert_operator Observability::Recorder::Journal.read(directory).length, :>, 1
    end
  end

  def test_bulk_saturation_is_counted_and_metric_cardinality_is_rejected
    recorder = Observability::Recorder::Memory.new(max_size: 1)
    producer = Observability::Producer.new(recorder:)
    producer.emit('tamoz.worker.error', attributes: {reason: 'one'})
    assert_equal :dropped, producer.emit('tamoz.worker.error', attributes: {reason: 'two'})
    assert_equal 1, recorder.health.fetch('drops').values.sum

    metrics = Observability::Metrics.new
    assert_equal :rejected, metrics.increment(
      'tamoz.turn.duration_ms', labels: {outcome: 'ok', profile: 'p', surface: 's', thread_id: 'secret'}
    )
    assert_equal 1, metrics.health.fetch('violations').fetch('tamoz.turn.duration_ms')
    metrics.increment(
      'tamoz.turn.duration_ms', value: 12,
      labels: {outcome: 'ok', profile: 'p', surface: 's'}
    )
    assert_equal 1, metrics.to_h.fetch('counters').length
  end

  def test_trace_from_documents_uses_durable_identity
    documents = [
      {
        'name' => 'tamoz.worker.request.completed',
        'kind' => 'event',
        'timing' => 'point',
        'observed_at_ms' => 10,
        'correlation' => {'thread_id' => 'thread.1', 'execution_id' => 'execution.1', 'occurrence_id' => 'occurrence.1'},
        'attributes' => {},
        'outcome' => 'ok'
      }
    ]
    first = Observability::Trace.from_documents(documents, thread_id: 'thread.1', execution_id: 'execution.1')
    second = Observability::Trace.from_documents(documents, thread_id: 'thread.1', execution_id: 'execution.1')

    assert_equal first.to_h, second.to_h
    assert_equal Observability::Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1'), first.trace_id
  end

  def test_model_call_records_measured_usage_and_labeled_estimated_cost
    recorder = Observability::Recorder::Memory.new
    producer = Observability::Producer.new(recorder:)
    usage = Observability::Usage.new(input_tokens: 100, output_tokens: 20, cache_read_tokens: nil, cache_write_tokens: nil)
    pricing = Observability::PricingTable.new(
      source: 'operator', version: '2026-08-11', input_per_million: 1.0, output_per_million: 2.0
    )
    cost = pricing.cost(usage)
    model = Observability::ModelCall.new(producer:, provider: 'fake', model: 'model-1')

    assert_equal :answer, model.call(
      correlation: {thread_id: 't', execution_id: 'e', request_id: 'r', task_id: 'task'},
      usage:, cost:
    ) { :answer }
    signal = recorder.signals.first
    assert_equal 100, signal.attributes.fetch(:input_tokens)
    assert_operator signal.attributes.fetch(:duration_ms), :>=, 0
    assert_equal :estimated, signal.attributes.fetch(:cost_basis)
    assert_equal 'operator', signal.attributes.fetch(:pricing_source)
  end
end
