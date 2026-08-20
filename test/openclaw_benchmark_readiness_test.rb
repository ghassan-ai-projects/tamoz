# frozen_string_literal: true

require_relative 'test_helper'

# The manifest helper and report fixture intentionally bind the complete evidence
# contract in one place.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Layout/LineLength
class OpenclawBenchmarkReadinessTest < Minitest::Test
  def protocol
    { 'benchmark_protocol_version' => 'openclaw.v1' }
  end

  def manifest(run_kind: 'real_provider', capability: nil, mission_status: 'ready', controls_passed: true)
    {
      'protocol_sha256' => Tamoz::Evals::Benchmark::Readiness.protocol_digest(protocol),
      'run_kind' => run_kind,
      'provider' => 'provider-a',
      'model' => 'model-a',
      'artifact_root' => run_kind == 'fixture' ? 'fixtures/run-1' : 'real-provider/run-1',
      'git_revision' => "sha256:#{'c' * 64}",
      'config_sha256' => "sha256:#{'d' * 64}",
      'graph' => { 'name' => 'tamoz.agent.session', 'version' => '2' },
      'surfaces' => %w[cli telegram],
      'command' => 'script/benchmark_openclaw_readiness',
      'controls_passed' => controls_passed,
      'capabilities' => {
        'read_only' => capability || {
          'exists' => true, 'reachable' => true, 'authorized' => true,
          'attempted' => true, 'effective' => true, 'completed' => true,
          'verified' => true
        }
      },
      'missions' => [{
        'id' => 'adaptive-read-only',
        'status' => mission_status,
        'artifact_path' => 'adaptive-read-only.json',
        'artifact_digest' => "sha256:#{'a' * 64}"
      }]
    }
  end

  def test_ready_real_provider_manifest_is_publishable
    Dir.mktmpdir('openclaw-artifacts') do |directory|
      artifact = Pathname.new(directory).join('real-provider', 'run-1', 'adaptive-read-only.json')
      FileUtils.mkdir_p(artifact.dirname)
      File.write(artifact, 'evidence')
      digest = "sha256:#{Digest::SHA256.file(artifact).hexdigest}"
      ready_manifest = manifest.merge(
        'missions' => [manifest.fetch('missions').first.merge('artifact_digest' => digest)]
      )
      result = Tamoz::Evals::Benchmark::Readiness.evaluate(
        protocol:, manifest: ready_manifest, artifact_root_base: directory
      )

      assert_predicate result, :ready?
      assert_predicate result, :publishable?
      assert_empty result.reasons
    end
  end

  def test_fixture_manifest_is_ready_for_plumbing_but_not_publishable
    result = Tamoz::Evals::Benchmark::Readiness.evaluate(protocol:, manifest: manifest(run_kind: 'fixture'))

    refute_predicate result, :ready?
    refute_predicate result, :publishable?
    assert_includes result.reasons, 'fixture_or_fake_provider'
  end

  def test_unavailable_capability_blocks_final_readiness
    capability = {
      'exists' => true, 'reachable' => false, 'authorized' => true,
      'attempted' => false, 'effective' => false, 'completed' => false,
      'verified' => false
    }
    result = Tamoz::Evals::Benchmark::Readiness.evaluate(protocol:, manifest: manifest(capability:))

    refute_predicate result, :ready?
    assert_includes result.reasons, 'capability_unavailable:read_only:reachable/attempted/effective/completed/verified'
  end

  def test_publishable_assertion_refuses_missing_mission_artifact
    bad = manifest.merge('missions' => [{ 'id' => 'adaptive-read-only', 'status' => 'ready' }])

    assert_raises(Tamoz::Evals::DigestError) do
      Tamoz::Evals::Benchmark::Readiness.assert_publishable!(protocol:, manifest: bad)
    end
  end

  def test_report_carries_readiness_and_cannot_publish_an_unready_run
    readiness = Tamoz::Evals::Benchmark::Readiness.evaluate(
      protocol:, manifest: manifest(run_kind: 'fixture')
    )
    cell = {
      'cell_id' => 'cell-1', 'status' => 'produced', 'primary_code' => 'unknown',
      'truth_code' => 'unknown', 'probabilities' => { 'unknown' => 1.0 },
      'evidence_refs' => [], 'valid_evidence_ids' => [],
      'first_observable_at' => '2026-01-01T00:00:00Z', 'decision_at' => '2026-01-01T00:00:01Z',
      'gold_risk_class' => nil, 'intent_risk_classes' => [], 'facts' => {},
      'tokens' => 0, 'tool_bytes' => 0, 'scenario_family' => 'f'
    }
    report = Tamoz::Evals::Benchmark::Report.build(
      protocol: {
        'benchmark_protocol_version' => '1', 'thresholds' => { 'minimum_practical_effect' => 0.05, 'confidence_interval' => 0.95 },
        'statistics' => { 'bootstrap_seed' => 7, 'random_label_seed' => 1 }, 'baselines' => ['majority_prior'],
        'case_matrix' => { 'scenario_families' => [] }, 'scoring' => { 'utility' => { 'missed_catastrophe_cost' => 1.0, 'false_action_cost' => 1.0 } }
      },
      cells: [cell], model_identity: 'fixture', protocol_sha256: "sha256:#{'c' * 64}",
      label: 'pilot', controls_passed: true, readiness:
    )

    assert_equal readiness.to_h, report.fetch('readiness')
    assert_equal 'inconclusive', report.fetch('verdict')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Layout/LineLength
