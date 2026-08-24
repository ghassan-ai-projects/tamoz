# frozen_string_literal: true

require_relative 'test_helper'

# Phase B0 (docs/openclaw-chat-study/benchmark-protocol/03-implementation-plan.md):
# the nine canonical comms scenarios run through the composition harness as a
# fixture run — real Normalizer → Gateway admit → SQLite store → Worker drain →
# DeliveryDrainer receipts over a fake scripted transport and a deterministic
# provider — and score deterministically. The same inputs twice must produce
# byte-identical scores. No provider, no real transport, no claim.
class BenchmarkCommsB0Test < Minitest::Test
  Runner = Tamoz::Evals::Benchmark::OpenclawCommsRunner
  IndexPath = Pathname.new(ROOT).join('docs/openclaw-chat-study/benchmark-protocol/scenarios/SCENARIO_INDEX.json')

  def with_runner(**options)
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      runner = Runner.new(
        artifact_base: directory, artifact_root: 'fixtures/scenarios',
        git_revision: 'test-revision', command: 'test',
        scenario_index_path: IndexPath, **options
      )
      yield runner, directory
    end
  end

  def scores(runner)
    result = runner.run
    result.artifacts.to_h { |artifact| [artifact.fetch('scenario_id'), artifact.fetch('record')] }
  end

  def test_pairing_first_contact_and_controls_score_end_to_end
    with_runner(scenarios: ['C5']) do |runner, _|
      records = scores(runner)

      assert_equal 'ready', records.fetch('C5').fetch('status'), records.fetch('C5')['reason']
      assert_equal 1, records.fetch('C5').dig('metrics', 'command_parity')
      assert_equal 1, records.fetch('C5').dig('metrics', 'inbound_identity')
      assert_equal 1, records.fetch('C5').dig('metrics', 'authority_stability')
    end
  end

  def test_slow_request_liveness_ladder_scores_end_to_end
    with_runner(scenarios: ['C2']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C2')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'liveness')
      assert_equal 1, record.dig('metrics', 'progress_bound')
      assert_equal 1, record.dig('metrics', 'context_inclusion')
      assert_equal 'passed', record.dig('hard_zero', 'fabricated_milestone')
    end
  end

  def test_truthful_history_scores_end_to_end
    with_runner(scenarios: ['C1']) do |runner, _|
      records = scores(runner)
      record = records.fetch('C1')

      assert_equal 'ready', record.fetch('status'), record['reason']
      assert_equal 1, record.dig('metrics', 'admission_before_ack')
      assert_equal 1, record.dig('metrics', 'reference_stability')
      assert_equal 1, record.dig('metrics', 'completion')
      assert_equal 1, record.dig('metrics', 'delivery_axis')
      assert_equal 1, record.dig('metrics', 'context_inclusion')
    end
  end

  def test_identical_runs_produce_byte_identical_scores
    first = nil
    second = nil
    with_runner do |runner, _|
      first = scores(runner).to_json
    end
    with_runner do |runner, _|
      second = scores(runner).to_json
    end

    assert_equal first, second, 'scores must be deterministic across two identical runs'
  end

  def test_all_nine_catalog_scenarios_appear_with_pending_seams_named_not_faked
    with_runner do |runner, directory|
      result = runner.run
      manifest = JSON.parse(File.read(File.join(directory, 'fixtures/scenarios/manifest.json')))

      assert_equal %w[C1 C2 C3 C4 C5 C6 C7 C8 C9], manifest.fetch('scenarios')
      assert_equal %w[C6 C8], manifest.fetch('pending_seam').keys.sort
      assert_equal 'fixture', manifest.fetch('run_kind')
      assert manifest.fetch('fixture')
      assert_includes manifest.fetch('transport'), 'no_egress'
      scored = %w[C1 C2 C3 C4 C5 C7 C9]
      scored.each do |scenario|
        artifact = JSON.parse(
          File.read(File.join(directory, "fixtures/scenarios/#{scenario}.json"))
        )

        assert_equal 'fixture', artifact.fetch('run_kind')
        assert artifact.fetch('fixture')
        assert_equal Runner.const_get(:PROVIDER), artifact.fetch('provider')
        refute_nil artifact.fetch('seam_revisions')
      end
      pending = JSON.parse(
        File.read(File.join(directory, 'fixtures/scenarios/C8.json'))
      )

      assert_equal 'pending_seam', pending.dig('result', 'status')
      assert_instance_of String, pending.dig('result', 'reason')
      assert_equal result.manifest.fetch('results'), manifest.fetch('results')
    end
  end

  def test_readiness_refuses_publication_for_a_fixture_run
    protocol = {
      'graph' => { 'name' => 'comms-b0', 'version' => '1' },
      'protocol_version' => 1,
      'missions' => [],
      'controls' => []
    }
    readiness_module = Tamoz::Evals::Benchmark::Readiness
    manifest = {
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
      'capabilities' => {
        'comms_channel' => { 'exists' => true, 'reachable' => true, 'authorized' => true,
                             'attempted' => true, 'effective' => true, 'completed' => true,
                             'verified' => true }
      },
      'controls_passed' => false,
      'missions' => [{
        'id' => 'c1', 'status' => 'blocked',
        'metrics_schema_version' => Tamoz::Evals::Benchmark::OpenclawMissionRunner::METRICS_SCHEMA_VERSION,
        'metrics' => { 'completion' => 1 },
        'hard_zero' => { 'ack_before_admission' => 'passed' },
        'effect_outcomes' => [],
        'surface_executions' => {
          'cli' => { 'status' => 'executed', 'provenance' => { 'surface' => 'cli' } },
          'telegram' => { 'status' => 'executed', 'provenance' => { 'surface' => 'telegram' } }
        }
      }],
      'surface_executions' => {}
    }
    Dir.mktmpdir('tamoz-comms-b0') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'fixtures/scenarios'))
      readiness = readiness_module.evaluate(
        protocol:, manifest:, expected_mission_ids: %w[c1],
        mission_catalog: {
          'schema_version' => 'openclaw.missions.v1',
          'missions' => [{
            'id' => 'c1', 'goal' => 'answer a short turn',
            'metrics' => %w[completion], 'hard_zero' => %w[ack_before_admission],
            'required_capabilities' => ['comms_channel'], 'surfaces' => %w[cli telegram]
          }]
        },
        artifact_root_base: directory
      )

      refute readiness.publishable?, 'a fixture run must never be publishable'
      assert_includes readiness.reasons, 'fixture_or_fake_provider'
    end
  end
end
