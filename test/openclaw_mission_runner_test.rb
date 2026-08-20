# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
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
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
