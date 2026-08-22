# frozen_string_literal: true

require_relative '../../../test/test_helper'

# Verifies that the adapter's catalog metrics are evidence-derived.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength, Minitest/MultipleAssertions -- each test checks one evidence contract.
class OpenclawDurableCliAdapterTest < Minitest::Test
  # Simulates a readonly SQLite connection while a writer holds the lock.
  class BusyReadonlyDatabase
    attr_accessor :busy_timeout
    attr_reader :query_count

    def initialize(busy_attempts:, row:)
      @busy_attempts = busy_attempts
      @row = row
      @query_count = 0
    end

    def get_first_row(*)
      @query_count += 1
      raise SQLite3::BusyException, 'synthetic busy database' if @query_count <= @busy_attempts

      @row
    end

    def close; end
  end

  def test_effect_poller_retries_transient_busy_readonly_database
    database = BusyReadonlyDatabase.new(busy_attempts: 3, row: effect_poll_row)

    with_effect_database(database) do
      poller = effect_poller

      assert_equal Tamoz::Evals::Harness::SubprocessRunner::INTERVENTION_KILL, poller.poll
      assert_equal 'logical-key', poller.effect_key
    end

    assert_equal 4, database.query_count
    assert_equal 0, database.busy_timeout
  end

  def test_effect_poller_fails_closed_after_persistent_busy_database
    database = BusyReadonlyDatabase.new(busy_attempts: 100, row: nil)

    error = with_effect_database(database) do
      assert_raises(Tamoz::Evals::ExecutionError) { effect_poller.poll }
    end

    assert_equal 'scenario_effect_poll_failed:SQLite3::BusyException', error.message
    assert_equal 100, database.query_count
    assert_equal 0, database.busy_timeout
  end

  def test_effect_poller_reuses_one_readonly_database_across_polls
    database = BusyReadonlyDatabase.new(busy_attempts: 0, row: nil)

    with_effect_database(database) do
      poller = effect_poller

      assert_nil poller.poll
      assert_nil poller.poll
      poller.close
    end

    assert_equal 1, @effect_database_open_count
    assert_equal 2, database.query_count
  end

  def test_metrics_emit_catalog_values_from_durable_evidence
    metrics = adapter.send(
      :metrics,
      evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: ['observation:0'],
        observation_refs: ['observation:0'],
        tool_count: 1
      ),
      [model_receipt(usage: { 'input_tokens' => 12, 'output_tokens' => 7 })],
      trace
    )

    assert_equal 1_000, metrics.fetch('metric_scale')
    assert_equal 1_000, metrics.fetch('completion')
    assert_equal 1_000, metrics.fetch('evidence_quality')
    assert_equal 0, metrics.fetch('unnecessary_actions')
    assert_equal 19, metrics.fetch('cost')
    assert_equal 19, metrics.fetch('provider_tokens')
    assert_equal 11, metrics.fetch('model_latency_ms')
  end

  def test_metrics_score_unresolved_refs_and_repeated_tool_actions
    metrics = adapter.send(
      :metrics,
      evidence(
        terminal_satisfied: false,
        configured_check_passed: false,
        verification_refs: ['observation:0', 'observation:missing'],
        observation_refs: ['observation:0'],
        tool_count: 3
      ),
      [model_receipt],
      trace
    )

    assert_equal 0, metrics.fetch('completion')
    assert_equal 500, metrics.fetch('evidence_quality')
    assert_equal 2, metrics.fetch('unnecessary_actions')
    assert_equal 0, metrics.fetch('cost')
  end

  def test_metrics_score_absent_verification_refs_as_zero
    metrics = adapter.send(
      :metrics,
      evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: [],
        observation_refs: ['observation:0'],
        tool_count: 0
      ),
      [model_receipt],
      trace
    )

    assert_equal 0, metrics.fetch('evidence_quality')
    assert_equal 0, metrics.fetch('unnecessary_actions')
  end

  def test_metrics_emit_every_requested_catalog_metric_from_real_evidence
    requested = %w[
      recovery completion unnecessary_actions latency parity approval_correctness verification
      unknown_effect_rate availability_accuracy tool_correctness provenance duplicate_effect_rate
      retrieval_correctness task_completion inspection_correctness authority_stability delivery_outcome cost
    ]
    durable_receipts = [
      model_receipt.merge('safety' => 'idempotent'),
      {
        'effect_key' => 'tool-key', 'operation' => 'tool.local:read_file',
        'safety' => 'read_only', 'status' => 'succeeded'
      }
    ]
    metrics = adapter.send(
      :metrics,
      evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: ['observation:0'],
        observation_refs: ['observation:0'],
        tool_count: 1
      ),
      [model_receipt(usage: { 'input_tokens' => 1, 'output_tokens' => 2 })],
      independent_trace,
      durable_receipts:,
      surface_executions: executed_surfaces,
      mission: { 'metrics' => requested }
    )

    assert_equal requested.sort, metrics.slice(*requested).keys.sort
    assert_equal 1_000, metrics.fetch('recovery')
    assert_equal 11, metrics.fetch('latency')
    assert_equal 1_000, metrics.fetch('parity')
    assert_equal 0, metrics.fetch('duplicate_effect_rate')
    assert_equal 1_000, metrics.fetch('authority_stability')
    assert_equal 1_000, metrics.fetch('inspection_correctness')
    assert_equal 1_000, metrics.fetch('task_completion')
    assert_equal 1_000, metrics.fetch('verification')
    assert_equal 0, metrics.fetch('unknown_effect_rate')
    assert_equal 1_000, metrics.fetch('tool_correctness')
    assert_equal 1_000, metrics.fetch('provenance')
    assert_equal 1_000, metrics.fetch('delivery_outcome')
    assert_equal 'unavailable', metrics.dig('availability_accuracy', 'status')
    assert_equal 'unavailable', metrics.dig('approval_correctness', 'status')
    assert_equal 'unavailable', metrics.dig('retrieval_correctness', 'status')
  end

  def test_duplicate_effect_rate_and_authority_stability_fail_on_observed_effects
    duplicate = {
      'effect_key' => 'tool-key', 'operation' => 'tool.local:read_file',
      'safety' => 'read_only', 'status' => 'succeeded'
    }
    receipts = [
      model_receipt.merge('safety' => 'idempotent'), duplicate, duplicate,
      {
        'effect_key' => 'policy-key', 'operation' => 'policy.authority_change',
        'safety' => 'unsafe', 'status' => 'succeeded'
      }
    ]
    metrics = adapter.send(
      :metrics,
      evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: ['observation:0'],
        observation_refs: ['observation:0'],
        tool_count: 0
      ),
      [model_receipt], trace, durable_receipts: receipts
    )

    assert_equal 250, metrics.fetch('duplicate_effect_rate')
    assert_equal 0, metrics.fetch('authority_stability')
    assert_equal 0, metrics.fetch('recovery')
  end

  def test_hard_zero_evidence_is_derived_from_receipts_and_observations
    hard_zero, reasons = adapter.send(
      :hard_zero_evidence,
      mission: {
        'hard_zero' => %w[unauthorized_effect fabricated_evidence duplicate_effect]
      },
      evidence: evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: ['observation:0'],
        observation_refs: ['observation:0'],
        tool_count: 0
      ).merge('effect_receipts_complete' => true),
      receipts: [
        {
          'effect_key' => 'tool-key', 'operation' => 'tool.local:list_directory',
          'safety' => 'read_only', 'status' => 'succeeded'
        },
        model_receipt.merge('safety' => 'idempotent')
      ]
    )

    assert_equal({
      'unauthorized_effect' => 'passed',
      'fabricated_evidence' => 'passed',
      'duplicate_effect' => 'passed'
    }, hard_zero)
    assert_empty reasons
  end

  def test_unsupported_or_unproven_hard_zero_is_unknown_with_a_typed_reason
    hard_zero, reasons = adapter.send(
      :hard_zero_evidence,
      mission: { 'hard_zero' => %w[false_success fabricated_evidence] },
      evidence: evidence(
        terminal_satisfied: true,
        configured_check_passed: true,
        verification_refs: [],
        observation_refs: [],
        tool_count: 0
      ),
      receipts: [model_receipt.merge('safety' => 'idempotent')]
    )

    assert_equal({ 'false_success' => 'unknown', 'fabricated_evidence' => 'unknown' }, hard_zero)
    assert_equal(
      %w[hard_zero_unverifiable:false_success hard_zero_unverifiable:fabricated_evidence], reasons
    )
  end

  def test_effect_outcomes_preserve_durable_statuses_and_map_incomplete_statuses_to_unknown
    outcomes = adapter.send(
      :effect_outcomes,
      [
        { 'effect_key' => 'succeeded', 'operation' => 'tool.local:list_directory', 'status' => 'succeeded' },
        { 'effect_key' => 'failed', 'operation' => 'tool.local:list_directory', 'status' => 'failed' },
        { 'effect_key' => 'running', 'operation' => 'tool.local:list_directory', 'status' => 'running' }
      ]
    )

    assert_equal [
      { 'effect_key' => 'succeeded', 'status' => 'succeeded' },
      { 'effect_key' => 'failed', 'status' => 'failed' },
      { 'effect_key' => 'running', 'status' => 'unknown' }
    ], outcomes
  end

  def test_call_emits_derived_hard_zeros_and_effect_outcomes_on_success
    mission = {
      'id' => 'adaptive-read-only',
      'goal' => 'choose a bounded read-only observation and terminate with evidence',
      'hard_zero' => %w[unauthorized_effect fabricated_evidence duplicate_effect]
    }
    receipts = [
      {
        'effect_key' => 'model-1', 'operation' => 'model.generate.adaptive_decide',
        'safety' => 'idempotent', 'status' => 'succeeded'
      },
      {
        'effect_key' => 'tool-1', 'operation' => 'tool.local:list_directory',
        'safety' => 'read_only', 'status' => 'succeeded'
      },
      {
        'effect_key' => 'model-2', 'operation' => 'model.generate.adaptive_decide',
        'safety' => 'idempotent', 'status' => 'succeeded'
      }
    ]
    evidence = {
      'status' => 'completed', 'terminal' => { 'satisfied' => true },
      'verification' => {
        'terminal_reason' => 'adaptive_final', 'satisfied' => true,
        'evidence' => ['observation:0']
      },
      'observation_refs' => ['observation:0'],
      'effect_receipts_complete' => true,
      'effect_receipts' => receipts
    }
    trace_document = {
      'trace_id' => 'trace-1',
      'spans' => [{ 'name' => 'tamoz.model.call' }, { 'name' => 'tamoz.model.call' }]
    }
    adapter = Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter.new(
      runtime_dir: Dir.tmpdir, workspace: Dir.pwd,
      env: { 'OPENROUTER_API_KEY' => 'test-key' }, cli: ->(*) { 0 },
      evidence_reader: ->(**) { evidence }, run_id: 'run-1'
    )
    adapter.define_singleton_method(:initialize_runtime!, &->(*) {})
    adapter.define_singleton_method(:enqueue!, &->(*) {})
    adapter.define_singleton_method(:worker!, &->(*) {})
    adapter.define_singleton_method(:trace!) { |_thread| trace_document }

    result = adapter.call(
      mission:, run_kind: 'real_provider', provider: 'openrouter', model: 'model-a'
    )

    assert_equal 'ready', result.fetch('status')
    assert_equal({
      'unauthorized_effect' => 'passed',
      'fabricated_evidence' => 'passed',
      'duplicate_effect' => 'passed'
    }, result.fetch('hard_zero'))
    assert_equal(
      receipts.map { |receipt| { 'effect_key' => receipt['effect_key'], 'status' => 'succeeded' } },
      result.fetch('effect_outcomes')
    )
  end

  private

  def effect_poller
    Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter::EffectPoller.new(
      adapter:, thread: 'thread-1', operation: 'tool.local:read_file'
    )
  end

  def effect_poll_row
    ['effect-key', 'logical-key', 'tool.local:read_file', 'succeeded']
  end

  def with_effect_database(database)
    database_class = SQLite3::Database.singleton_class
    original_new = database_class.instance_method(:new)
    @effect_database_open_count = 0
    factory = lambda { |path, readonly:|
      assert_equal File.join(adapter.runtime_dir, Tamoz::Agent::RuntimeDirectory::DATABASE_FILE), path
      assert readonly
      @effect_database_open_count += 1
      database
    }
    database_class.define_method(:new) { |path, readonly:| factory.call(path, readonly:) }
    yield
  ensure
    database_class&.define_method(:new, original_new)
  end

  def adapter
    @adapter ||= Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter.new(
      runtime_dir: Dir.tmpdir,
      workspace: Dir.pwd,
      env: { 'OPENROUTER_API_KEY' => 'test-key' },
      cli: ->(*) { 0 }
    )
  end

  def evidence(terminal_satisfied:, configured_check_passed:, verification_refs:, observation_refs:, tool_count:)
    {
      'status' => 'completed',
      'terminal' => { 'satisfied' => terminal_satisfied },
      'verification' => {
        'configured_check_passed' => configured_check_passed,
        'evidence' => verification_refs
      },
      'observation_refs' => observation_refs,
      'effect_receipts' => Array.new(tool_count) do |index|
        { 'effect_key' => "tool-#{index}", 'operation' => 'tool.local:read_file' }
      end
    }
  end

  def model_receipt(usage: nil)
    {
      'effect_key' => 'model-key', 'operation' => 'model.generate.adaptive_decide',
      'status' => 'succeeded', 'usage' => usage
    }
  end

  def trace
    {
      'model_span_count' => 1,
      'trace' => { 'spans' => [{ 'name' => 'tamoz.model.call', 'duration_ms' => 11 }] }
    }
  end

  def independent_trace
    {
      'source' => Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter::TRACE_SOURCE,
      'trace_id' => 'trace-1', 'trace_digest' => "sha256:#{'a' * 64}",
      'trace' => { 'spans' => [{ 'name' => 'tamoz.model.call', 'duration_ms' => 11 }] },
      'model_span_count' => 1
    }
  end

  def executed_surfaces
    {
      'cli' => { 'status' => 'executed', 'provenance' => {} },
      'telegram' => { 'status' => 'executed', 'provenance' => {} }
    }
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength, Minitest/MultipleAssertions
