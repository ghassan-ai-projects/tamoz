# frozen_string_literal: true

require_relative 'test_helper'

# The manifest helper and report fixture intentionally bind the complete evidence
# contract in one place.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Layout/LineLength
class OpenclawBenchmarkReadinessTest < Minitest::Test
  def protocol
    { 'benchmark_protocol_version' => 'openclaw.v1' }
  end

  def manifest(run_kind: 'real_provider', capability: nil, mission_status: 'ready', controls_passed: true)
    {
      'runner_schema_version' => 'openclaw.evidence.v1',
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
      'surface_executions' => {
        'adaptive-read-only' => surface_executions(run_kind:)
      },
      'missions' => [{
        'id' => 'adaptive-read-only',
        'status' => mission_status,
        'artifact_path' => 'adaptive-read-only.json',
        'artifact_digest' => "sha256:#{'a' * 64}",
        'metrics_schema_version' => 'openclaw.metrics.v1',
        'metrics' => { 'completion' => 1 },
        'hard_zero' => { 'fabricated_evidence' => 'passed' },
        'effect_outcomes' => [],
        'surface_executions' => surface_executions(run_kind:),
        'durable_mission' => {
          'mission_id' => 'adaptive-read-only', 'run_id' => 'run-1', 'thread_id' => 'thread-1',
          'status' => 'completed', 'satisfied' => true, 'verified' => true
        }
      }]
    }
  end

  def surface_executions(run_kind: 'real_provider')
    %w[cli telegram].to_h do |surface|
      [surface, {
        'status' => 'executed',
        'provenance' => {
          'surface' => surface, 'run_kind' => run_kind, 'provider' => 'provider-a', 'model' => 'model-a'
        }
      }]
    end
  end

  def test_ready_real_provider_manifest_is_publishable
    Dir.mktmpdir('openclaw-artifacts') do |directory|
      artifact = Pathname.new(directory).join('real-provider', 'run-1', 'adaptive-read-only.json')
      FileUtils.mkdir_p(artifact.dirname)
      mission = { 'id' => 'adaptive-read-only' }
      mission_digest = "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(mission))}"
      document = {
        'schema_version' => 'openclaw.evidence.v1',
        'protocol_sha256' => Tamoz::Evals::Benchmark::Readiness.protocol_digest(protocol),
        'mission_id' => 'adaptive-read-only',
        'mission_digest' => mission_digest,
        'run_kind' => 'real_provider', 'provider' => 'provider-a', 'model' => 'model-a',
        'git_revision' => "sha256:#{'c' * 64}", 'config_sha256' => "sha256:#{'d' * 64}",
        'mission' => mission,
        'provenance' => provider_provenance(mission_digest:),
        'result' => {
          'status' => 'ready', 'metrics_schema_version' => 'openclaw.metrics.v1',
          'metrics' => { 'completion' => 1 },
          'hard_zero' => { 'fabricated_evidence' => 'passed' }, 'effect_outcomes' => [],
          'surface_executions' => surface_executions
        }
      }
      File.write(artifact, JSON.generate(document))
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

  def provider_provenance(mission_digest: nil)
    receipts = [{
      'effect_key' => "logical:#{'a' * 64}",
      'operation' => 'model.generate.plan',
      'status' => 'succeeded'
    }]
    trace = { 'trace_id' => 'trace-1', 'spans' => [{ 'name' => 'tamoz.model.call' }] }
    independent_trace = {
      'source' => Tamoz::Evals::Benchmark::Readiness::INDEPENDENT_TRACE_SOURCE,
      'run_id' => 'run-1', 'thread_id' => 'thread-1', 'mission_id' => 'adaptive-read-only',
      'trace_id' => trace.fetch('trace_id'),
      'trace_digest' => "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(trace))}",
      'trace' => trace, 'model_span_count' => 1
    }
    {
      'run_kind' => 'real_provider', 'provider' => 'provider-a', 'model' => 'model-a',
      'surface_executions' => surface_executions,
      'provider_effect_receipts' => receipts,
      'provider_trace_digest' => Tamoz::Evals::Benchmark::Readiness.provider_trace_digest(
        mission_digest:, receipts:, independent_trace:
      ),
      'independent_trace' => independent_trace
    }
  end

  def test_plain_text_artifact_cannot_be_published_as_provider_evidence
    Dir.mktmpdir('openclaw-artifacts') do |directory|
      artifact = Pathname.new(directory).join('real-provider', 'run-1', 'adaptive-read-only.json')
      FileUtils.mkdir_p(artifact.dirname)
      File.write(artifact, 'ready: true\n')
      ready_manifest = manifest.merge(
        'missions' => [manifest.fetch('missions').first.merge(
          'artifact_digest' => "sha256:#{Digest::SHA256.file(artifact).hexdigest}"
        )]
      )

      result = Tamoz::Evals::Benchmark::Readiness.evaluate(
        protocol:, manifest: ready_manifest, artifact_root_base: directory
      )

      refute_predicate result, :ready?
      assert_includes result.reasons, 'artifact_schema_invalid:adaptive-read-only'
    end
  end

  def test_fixture_manifest_is_ready_for_plumbing_but_not_publishable
    result = Tamoz::Evals::Benchmark::Readiness.evaluate(protocol:, manifest: manifest(run_kind: 'fixture'))

    refute_predicate result, :ready?
    refute_predicate result, :publishable?
    assert_includes result.reasons, 'fixture_or_fake_provider'
  end

  def test_real_provider_artifact_without_independent_trace_is_not_publishable
    Dir.mktmpdir('openclaw-artifacts') do |directory|
      artifact = Pathname.new(directory).join('real-provider', 'run-1', 'adaptive-read-only.json')
      FileUtils.mkdir_p(artifact.dirname)
      mission = { 'id' => 'adaptive-read-only' }
      mission_digest = "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(mission))}"
      document = {
        'schema_version' => 'openclaw.evidence.v1',
        'protocol_sha256' => Tamoz::Evals::Benchmark::Readiness.protocol_digest(protocol),
        'mission_id' => mission.fetch('id'), 'mission_digest' => mission_digest,
        'run_kind' => 'real_provider', 'provider' => 'provider-a', 'model' => 'model-a',
        'git_revision' => "sha256:#{'c' * 64}", 'config_sha256' => "sha256:#{'d' * 64}",
        'mission' => mission, 'provenance' => provider_provenance(mission_digest:).except('independent_trace'),
        'result' => {
          'status' => 'ready', 'metrics_schema_version' => 'openclaw.metrics.v1',
          'metrics' => { 'completion' => 1 },
          'hard_zero' => { 'fabricated_evidence' => 'passed' }, 'effect_outcomes' => [],
          'surface_executions' => surface_executions
        }
      }
      File.write(artifact, JSON.generate(document))
      ready_manifest = manifest.merge(
        'missions' => [manifest.fetch('missions').first.merge(
          'artifact_digest' => "sha256:#{Digest::SHA256.file(artifact).hexdigest}"
        )]
      )

      result = Tamoz::Evals::Benchmark::Readiness.evaluate(
        protocol:, manifest: ready_manifest, artifact_root_base: directory
      )

      refute_predicate result, :ready?
      assert_includes result.reasons, 'artifact_independent_trace_unavailable:adaptive-read-only'
    end
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

    assert_raises(Tamoz::Evals::SchemaError) do
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

  def test_catalog_required_capability_is_checked_against_manifest_state
    catalog = {
      'schema_version' => 'openclaw.missions.v1',
      'missions' => [{
        'id' => 'adaptive-read-only', 'goal' => 'read and report',
        'surfaces' => %w[cli telegram], 'required_capabilities' => ['local:read_file'],
        'metrics' => ['completion'], 'hard_zero' => ['fabricated_evidence']
      }]
    }
    blocked = Tamoz::Evals::Benchmark::Readiness.evaluate(
      protocol:, manifest:, mission_catalog: catalog
    )

    refute_predicate blocked, :ready?
    assert_includes blocked.reasons,
                    'mission_capability_unavailable:adaptive-read-only:local:read_file'
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Layout/LineLength
