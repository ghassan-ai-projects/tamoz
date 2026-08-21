# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Minitest/MultipleAssertions
class OpenclawMissionRunnerTest < Minitest::Test
  def protocol
    { 'benchmark_protocol_version' => 'openclaw.v1' }
  end

  def catalog
    {
      'schema_version' => 'openclaw.missions.v1',
      'missions' => [
        {
          'id' => 'adaptive-read-only', 'goal' => 'read and report', 'surfaces' => %w[cli telegram],
          'required_capabilities' => ['local:read_file'], 'metrics' => ['completion'],
          'hard_zero' => ['fabricated_evidence']
        },
        {
          'id' => 'self-inspection', 'goal' => 'inspect safely', 'surfaces' => %w[cli telegram],
          'required_capabilities' => ['local:read_file'], 'metrics' => ['cost'],
          'hard_zero' => ['unauthorized_effect']
        }
      ]
    }
  end

  def capabilities
    state = {
      'exists' => true, 'reachable' => true, 'authorized' => true,
      'attempted' => true, 'effective' => true, 'completed' => true, 'verified' => true
    }
    { 'local:read_file' => state }
  end

  def runner(directory, executor:, run_kind: 'fixture')
    Tamoz::Evals::Benchmark::OpenclawMissionRunner.new(
      protocol:,
      catalog:,
      run_kind:,
      provider: run_kind == 'fixture' ? 'fixture-provider' : 'provider-a',
      model: run_kind == 'fixture' ? 'fixture-model' : 'model-a',
      artifact_root: run_kind == 'fixture' ? 'fixtures/run-1' : 'real-provider/run-1',
      artifact_base: directory,
      git_revision: "sha256:#{'c' * 64}",
      config_sha256: "sha256:#{'d' * 64}",
      graph: { 'name' => 'tamoz.agent.session', 'version' => '2' },
      surfaces: %w[cli telegram],
      capabilities: capabilities,
      controls_passed: true,
      command: 'test/openclaw_mission_runner_test.rb',
      executor:
    )
  end

  def test_runner_writes_digest_bound_fixture_artifacts_and_readiness_accepts_them
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, executor: lambda do |mission:, run_kind:, **|
        {
          'status' => 'ready',
          'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
          'metrics' => mission.fetch('metrics').to_h { |metric| [metric, 1] },
          'hard_zero' => mission.fetch('hard_zero').to_h { |rule| [rule, 'passed'] },
          'effect_outcomes' => [],
          'surface_executions' => surface_executions(mission, run_kind:),
          'provenance' => {
            'run_kind' => run_kind, 'provider' => 'fixture-provider', 'model' => 'fixture-model',
            'provider_calls' => 0
          },
          'trace' => [{ 'mission_id' => mission.fetch('id'), 'tool' => 'local:read_file' }]
        }
      end).run

      manifest = result.manifest
      readiness = Tamoz::Evals::Benchmark::Readiness.evaluate(
        protocol:, manifest:, expected_mission_ids: catalog.fetch('missions').map { |m| m.fetch('id') },
        mission_catalog: catalog, artifact_root_base: directory
      )

      assert_equal 2, result.artifacts.length
      manifest_path = Pathname.new(directory).join(manifest.fetch('artifact_root'), 'manifest.json')

      assert_predicate manifest_path, :file?
      assert_equal manifest, JSON.parse(File.read(manifest_path))
      refute_predicate readiness, :ready?
      assert_includes readiness.reasons, 'fixture_or_fake_provider'
      assert readiness.manifest.fetch('artifacts_verified')
      refute_predicate readiness, :publishable?
      result.artifacts.each do |artifact|
        path = Pathname.new(directory).join(manifest.fetch('artifact_root'), artifact.fetch('artifact').fetch('path'))

        assert_predicate path, :file?
        assert_equal artifact.fetch('artifact').fetch('digest'),
                     "sha256:#{Digest::SHA256.file(path).hexdigest}"
      end
    end
  end

  def test_real_provider_ready_result_requires_provider_call_provenance
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, run_kind: 'real_provider', executor: lambda { |**|
        {
          'status' => 'ready',
          'provenance' => {
            'run_kind' => 'real_provider', 'provider' => 'provider-a', 'model' => 'model-a',
            'provider_calls' => 0
          }
        }
      }).run

      assert_equal(%w[blocked blocked], result.manifest.fetch('missions').map { |mission| mission.fetch('status') })
      assert(result.manifest.fetch('missions').all? do |mission|
        mission.fetch('reason').start_with?('executor_error:')
      end)
    end
  end

  def test_executor_failure_reason_does_not_expose_exception_text
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, executor: lambda {
        raise StandardError, 'OPENAI_API_KEY=sk-secret-value'
      }).run

      mission = result.manifest.fetch('missions').first

      assert_equal 'blocked', mission.fetch('status')
      assert_match 'executor_error:', mission.fetch('reason')
      refute_includes mission.fetch('reason'), 'sk-secret-value'
    end
  end

  def test_real_provider_accepts_only_a_digest_bound_model_receipt_set
    Dir.mktmpdir('openclaw-runner') do |directory|
      receipts = [{
        'effect_key' => "logical:#{'a' * 64}",
        'operation' => 'model.generate.plan',
        'status' => 'succeeded'
      }]
      result = runner(directory, run_kind: 'real_provider', executor: lambda { |mission:, **|
        mission_digest = "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(mission))}"
        trace = independent_trace(mission_id: mission.fetch('id'))
        receipts_digest = Tamoz::Evals::Benchmark::Readiness.provider_trace_digest(
          mission_digest:, receipts:, independent_trace: trace
        )
        {
          'status' => 'ready',
          'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
          'metrics' => mission.fetch('metrics').to_h { |metric| [metric, 1] },
          'hard_zero' => mission.fetch('hard_zero').to_h { |rule| [rule, 'passed'] },
          'effect_outcomes' => [],
          'surface_executions' => surface_executions(mission, run_kind: 'real_provider'),
          'provenance' => {
            'run_kind' => 'real_provider', 'provider' => 'provider-a', 'model' => 'model-a',
            'provider_effect_receipts' => receipts,
            'provider_trace_digest' => receipts_digest,
            'independent_trace' => trace
          },
          'durable_mission' => {
            'mission_id' => mission.fetch('id'), 'run_id' => 'run-1', 'thread_id' => 'thread-1',
            'status' => 'completed', 'satisfied' => true, 'verified' => true
          }
        }
      }).run

      assert_equal(%w[ready ready], result.manifest.fetch('missions').map { |mission| mission.fetch('status') })
      assert_equal 2, result.artifacts.length
    end
  end

  def test_failed_and_unknown_outcomes_are_recorded_without_artifacts
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, executor: lambda do |mission:, **|
        if mission.fetch('id') == 'adaptive-read-only'
          {
            'status' => 'failed', 'reason' => 'mutation_rejected',
            'effect_outcomes' => [{ 'effect_key' => 'effect-1', 'status' => 'failed' }]
          }
        else
          { 'status' => 'unknown', 'reason' => 'receipt_lost' }
        end
      end).run

      records = result.manifest.fetch('missions')

      assert_equal(%w[failed unknown], records.map { |record| record.fetch('status') })
      assert_equal 'failed', records.first.fetch('effect_outcomes').first.fetch('status')
      assert_equal 'unknown', records.last.fetch('hard_zero').values.first

      assert(records.all? { |record| record.fetch('artifact_path', nil).nil? })
    end
  end

  def test_ready_result_with_incomplete_metrics_is_blocked
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, executor: lambda do |**|
        {
          'status' => 'ready', 'metrics' => {},
          'provenance' => { 'run_kind' => 'fixture', 'provider' => 'fixture-provider', 'model' => 'fixture-model' }
        }
      end).run

      assert(result.manifest.fetch('missions').all? do |record|
        record.fetch('status') == 'blocked' && record.fetch('reason').start_with?('executor_error:')
      end)
    end
  end

  def test_ready_result_with_unexecuted_surface_is_unavailable
    Dir.mktmpdir('openclaw-runner') do |directory|
      result = runner(directory, executor: lambda do |mission:, run_kind:, **|
        {
          'status' => 'ready',
          'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
          'metrics' => mission.fetch('metrics').to_h { |metric| [metric, 1] },
          'hard_zero' => mission.fetch('hard_zero').to_h { |rule| [rule, 'passed'] },
          'surface_executions' => surface_executions(mission, run_kind:).merge(
            'telegram' => surface_executions(mission, run_kind:).fetch('telegram').merge('status' => 'unavailable')
          ),
          'provenance' => { 'run_kind' => run_kind, 'provider' => 'fixture-provider', 'model' => 'fixture-model' }
        }
      end).run

      assert(result.manifest.fetch('missions').all? { |record| record.fetch('status') == 'unavailable' })
    end
  end

  def independent_trace(mission_id:)
    trace = {
      'trace_id' => 'trace-1', 'spans' => [{ 'name' => 'tamoz.model.call' }]
    }
    {
      'source' => Tamoz::Evals::Benchmark::Readiness::INDEPENDENT_TRACE_SOURCE,
      'run_id' => 'run-1', 'thread_id' => 'thread-1', 'mission_id' => mission_id,
      'trace_id' => trace.fetch('trace_id'),
      'trace_digest' => "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(trace))}",
      'trace' => trace,
      'model_span_count' => 1
    }
  end

  def surface_executions(mission, run_kind:)
    mission.fetch('surfaces').to_h do |surface|
      [surface, {
        'status' => 'executed',
        'provenance' => {
          'surface' => surface, 'run_kind' => run_kind,
          'provider' => run_kind == 'fixture' ? 'fixture-provider' : 'provider-a',
          'model' => run_kind == 'fixture' ? 'fixture-model' : 'model-a'
        }
      }]
    end
  end

  def test_catalog_mission_id_cannot_escape_the_artifact_directory
    bad_catalog = catalog.merge(
      'missions' => [catalog.fetch('missions').first.merge('id' => '../../victim')]
    )

    assert_raises(Tamoz::Evals::SchemaError) do
      Tamoz::Evals::Benchmark::OpenclawMissionRunner.new(
        protocol:, catalog: bad_catalog, run_kind: 'fixture', provider: 'fixture-provider',
        model: 'fixture-model', artifact_root: 'fixtures/run-1', artifact_base: Dir.tmpdir,
        git_revision: "sha256:#{'c' * 64}", config_sha256: "sha256:#{'d' * 64}",
        graph: { 'name' => 'tamoz.agent.session', 'version' => '2' }, surfaces: %w[cli telegram],
        capabilities:, controls_passed: true, command: 'test', executor: ->(**) { { 'status' => 'blocked' } }
      )
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Minitest/MultipleAssertions
