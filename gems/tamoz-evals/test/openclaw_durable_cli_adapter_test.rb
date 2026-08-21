# frozen_string_literal: true

require_relative '../../../test/test_helper'

# Verifies that the adapter's catalog metrics are evidence-derived.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions -- each test checks one evidence contract.
class OpenclawDurableCliAdapterTest < Minitest::Test
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
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
