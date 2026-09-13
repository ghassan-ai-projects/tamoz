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

  def test_journal_read_ignores_drop_health_sidecars
    Dir.mktmpdir do |directory|
      journal = Observability::Recorder::Journal.new(
        directory:, role: 'worker', queue_size: 1, flush_interval_ms: 1_000
      )
      producer = Observability::Producer.new(recorder: journal)
      100.times { producer.emit('tamoz.worker.error', attributes: {reason: 'x'}) }
      journal.close

      documents = Observability::Recorder::Journal.read(directory)
      assert documents.all? { |document| document.key?('name') }
      assert_operator Observability::Recorder::Journal.inventory(directory).fetch('drops'), :>, 0
    end
  end

  def test_journal_cap_survives_reopen_and_one_file_retention
    Dir.mktmpdir do |directory|
      2.times do
        journal = Observability::Recorder::Journal.new(
          directory:, role: 'worker', pid: 7, max_file_bytes: 512, max_files: 1,
          flush_interval_ms: 1
        )
        producer = Observability::Producer.new(recorder: journal)
        12.times { producer.emit('tamoz.worker.error', attributes: {reason: 'x' * 20}) }
        assert_equal 0, journal.flush(deadline_ms: 1_000)
        journal.close
      end

      files = Dir.glob(File.join(directory, 'worker-7.ndjson*')).reject { |file| file.end_with?('.health.json') }
      assert_equal 1, files.length
      assert_operator File.size(files.first), :<=, 512
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

  def test_metrics_bound_series_and_histogram_samples
    metrics = Observability::Metrics.new(max_series: 2, max_histogram_samples: 2)
    2.times do |index|
      assert_equal 1.0, metrics.increment(
        'tamoz.turn.duration_ms', labels: {outcome: 'ok', profile: 'p', surface: "s#{index}"}
      )
    end
    assert_equal :rejected, metrics.increment(
      'tamoz.turn.duration_ms', labels: {outcome: 'ok', profile: 'p', surface: 's2'}
    )

    histogram = Observability::Metrics.new(max_histogram_samples: 2)
    2.times { assert_equal 1.0, histogram.observe('tamoz.model.call.duration_ms', 1, labels: {provider: 'p', model: 'm', outcome: 'ok'}) }
    assert_equal :rejected, histogram.observe(
      'tamoz.model.call.duration_ms', 1, labels: {provider: 'p', model: 'm', outcome: 'ok'}
    )
  end

  def test_content_policy_rejects_oversized_hashes_before_serializing
    content = 65.times.to_h { |index| ["key#{index}", 'value'] }

    assert_raises(Observability::ValidationError) do
      Observability::ContentPolicy::NONE.describe(:error_detail, content)
    end
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

  def test_fanout_maps_a_raising_child_to_its_method_fallback_not_a_crash
    raising = Class.new do
      def record(_signal) = raise 'boom'
      def health = raise 'boom'
      def flush(deadline_ms:) = raise 'boom'
      def close = raise 'boom'
    end.new
    healthy = Observability::Recorder::Memory.new
    fanout = Observability::Recorder::Fanout.new([raising, healthy])

    # flush must not surface the guard sentinel through Integer() (regression:
    # a raising child previously crashed with TypeError instead of counting 0).
    assert_equal 0, fanout.flush(deadline_ms: 10)
    # health reports the child as unavailable rather than injecting :dropped.
    assert_equal({'enabled' => false, 'error' => 'unavailable'}, fanout.health.fetch('0'))
    assert_equal true, fanout.health.fetch('1').fetch('enabled')
    assert_nil fanout.close
  end
end
