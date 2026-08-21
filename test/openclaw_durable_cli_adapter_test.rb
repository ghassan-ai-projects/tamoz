# frozen_string_literal: true

require_relative 'test_helper'

# The adapter integration checks deliberately assert the durable command sequence
# and the independent trace binding in one scenario.
# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
class OpenclawDurableCliAdapterTest < Minitest::Test
  MISSION = {
    'id' => 'adaptive-read-only',
    'goal' => 'choose a bounded read-only observation and terminate with evidence'
  }.freeze

  def test_uses_queue_worker_and_independent_trace_to_build_real_provider_evidence
    Dir.mktmpdir('openclaw-adapter') do |directory|
      workspace = File.join(directory, 'workspace')
      runtime = File.join(directory, 'runtime')
      FileUtils.mkdir_p(workspace)
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace:)
      commands = []
      cli = fake_cli(commands)
      adapter = Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter.new(
        runtime_dir: runtime, workspace:, env: { 'OPENAI_API_KEY' => 'test-key' }, cli:,
        evidence_reader: ->(**) { durable_evidence }
      )

      result = adapter.call(mission: MISSION, run_kind: 'real_provider', provider: 'openai', model: 'gpt-test')

      assert_equal 'ready', result.fetch('status')
      assert_equal 1, result.dig('metrics', 'model_calls')
      assert_equal 'tamoz.observability.journal', result.dig('provenance', 'independent_trace', 'source')
      assert(commands.any? { |argv| argv.include?('queue') && argv.include?('add') })
      assert(commands.any? { |argv| argv.include?('worker') && argv.include?('--once') })
      assert(commands.any? { |argv| argv.include?('trace') })
    end
  end

  def test_missing_provider_credentials_blocks_before_cli_execution
    cli_calls = 0
    adapter = Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter.new(
      runtime_dir: Dir.tmpdir, workspace: Dir.pwd, env: {},
      cli: lambda { |**|
        cli_calls += 1
        0
      }, evidence_reader: ->(**) { durable_evidence }
    )

    result = adapter.call(mission: MISSION, run_kind: 'real_provider', provider: 'openai', model: 'gpt-test')

    assert_equal 'blocked', result.fetch('status')
    assert_equal 'provider_credential_unavailable:OPENAI_API_KEY', result.fetch('reason')
    assert_equal 0, cli_calls
  end

  def test_missing_independent_model_trace_blocks_the_mission
    Dir.mktmpdir('openclaw-adapter') do |directory|
      workspace = File.join(directory, 'workspace')
      runtime = File.join(directory, 'runtime')
      FileUtils.mkdir_p(workspace)
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace:)
      cli = fake_cli([], trace: { 'trace_id' => 'trace-1', 'spans' => [] })
      adapter = Tamoz::Evals::Benchmark::OpenclawDurableCliAdapter.new(
        runtime_dir: runtime, workspace:, env: { 'OPENAI_API_KEY' => 'test-key' }, cli:,
        evidence_reader: ->(**) { durable_evidence }
      )

      result = adapter.call(mission: MISSION, run_kind: 'real_provider', provider: 'openai', model: 'gpt-test')

      assert_equal 'blocked', result.fetch('status')
      assert_equal 'independent_trace_missing_model_spans', result.fetch('reason')
    end
  end

  private

  def durable_evidence
    {
      'status' => :completed,
      'terminal' => { 'reason' => 'completed', 'satisfied' => true },
      'verification' => { 'configured_check_passed' => true },
      'effect_receipts' => [{
        'effect_key' => "logical:#{'a' * 64}",
        'operation' => 'model.generate.plan',
        'status' => 'succeeded'
      }]
    }
  end

  def fake_cli(commands, trace: nil)
    trace ||= { 'trace_id' => 'trace-1', 'spans' => [{ 'name' => 'tamoz.model.call' }] }
    lambda do |argv, out:, **|
      commands << argv
      if argv.include?('trace')
        out.puts JSON.generate(trace)
      elsif argv.include?('queue')
        out.puts JSON.generate('thread' => argv.fetch(argv.index('--thread') + 1), 'status' => 'queued')
      else
        out.puts JSON.generate('event' => 'worker.stopped', 'reason' => 'idle')
      end
      0
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
