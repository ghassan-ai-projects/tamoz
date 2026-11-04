# frozen_string_literal: true

require_relative 'test_helper'

# Phase B0: a fixture run is never publishable, whatever its scores say.
class BenchmarkCommsB0ReadinessTest < Minitest::Test
  PROTOCOL = { 'graph' => { 'name' => 'comms-b0', 'version' => '1' }, 'protocol_version' => 1, 'missions' => [],
               'controls' => [] }.freeze

  CAPABILITIES = {
    'comms_channel' => { 'exists' => true, 'reachable' => true, 'authorized' => true,
                         'attempted' => true, 'effective' => true, 'completed' => true,
                         'verified' => true }
  }.freeze

  def readiness_manifest(readiness_module, protocol)
    {
      'runner_schema_version' => readiness_module::EVIDENCE_SCHEMA_VERSION,
      'protocol_sha256' => readiness_module.protocol_digest(protocol),
      'run_kind' => 'fixture',
      'provider' => 'fixture:deterministic-scripted',
      'model' => 'scripted-provider',
      'artifact_root' => 'fixtures/scenarios',
      'git_revision' => 'test-revision',
      'config_sha256' => "sha256:#{'a' * 64}",
      'graph' => { 'name' => 'comms-b0', 'version' => '1' },
      'surfaces' => %w[cli telegram],
      'command' => 'script/benchmark_comms_run',
      'capabilities' => CAPABILITIES,
      'controls_passed' => false,
      'missions' => [readiness_mission],
      'surface_executions' => {}
    }
  end

  def readiness_mission
    {
      'id' => 'c1', 'status' => 'blocked',
      'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
      'metrics' => { 'completion' => 1 },
      'hard_zero' => { 'reply_without_admission' => 'passed' },
      'effect_outcomes' => [],
      'surface_executions' => {
        'cli' => { 'status' => 'executed', 'provenance' => { 'surface' => 'cli' } },
        'telegram' => { 'status' => 'executed', 'provenance' => { 'surface' => 'telegram' } }
      }
    }
  end

  READINESS_CATALOG = {
    'schema_version' => 'openclaw.missions.v1',
    'missions' => [{
      'id' => 'c1', 'goal' => 'answer a short turn',
      'metrics' => %w[completion], 'hard_zero' => %w[reply_without_admission],
      'required_capabilities' => ['comms_channel'], 'surfaces' => %w[cli telegram]
    }]
  }.freeze

  def test_readiness_refuses_publication_for_a_fixture_run
    readiness_module = Tamoz::Evals::Benchmark::Readiness
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'fixtures/scenarios'))
      readiness = readiness_module.evaluate(
        protocol: PROTOCOL, manifest: readiness_manifest(readiness_module, PROTOCOL), expected_mission_ids: %w[c1],
        mission_catalog: READINESS_CATALOG, artifact_root_base: directory
      )

      refute_predicate readiness, :publishable?, 'a fixture run must never be publishable'
      assert_includes readiness.reasons, 'fixture_or_fake_provider'
    end
  end
end
