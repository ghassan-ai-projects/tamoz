# frozen_string_literal: true

require_relative '../../../test/test_helper'

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Minitest/MultipleAssertions, Style/Documentation
class ComparisonExecutorTest < Minitest::Test
  SCRIPT = ROOT.join('script', 'benchmark_openclaw_cells')

  def test_builds_cells_and_a_canonical_report_from_an_accepted_manifest
    Dir.mktmpdir('benchmark-cells') do |directory|
      root = Pathname.new(directory)
      manifest = write_synthetic_run(root)
      report = Tamoz::Evals::Benchmark::ComparisonExecutor.build(
        manifest:, protocol:, artifact_base: root
      )
      cell = report.fetch('cells').fetch(0)

      assert_equal 'adaptive-read-only:cli:run-1', cell.fetch('cell_id')
      assert_equal 'do-crash', cell.fetch('cluster_id')
      assert_equal 'low_dissolved_oxygen', cell.fetch('truth_code')
      assert_equal 'low_dissolved_oxygen', cell.fetch('primary_code')
      assert_equal({ 'low_dissolved_oxygen' => 750, 'unknown' => 250 }, cell.fetch('probabilities'))
      assert_equal 'completed', cell.fetch('status')
      assert_equal '2026-08-21T12:00:04.000Z', cell.fetch('decision_at')
      assert_equal '2026-08-21T12:00:02.000Z', cell.fetch('first_observable_at')
      assert_equal %w[effect-a effect-b model-1 model-2], cell.fetch('evidence_refs')
      assert_equal %w[effect-a model-1], cell.fetch('valid_evidence_ids')
      assert_equal 'inconclusive', report.fetch('verdict')
      assert_equal 1, report.fetch('cell_count')
      assert_no_floats(report)

      report_path = root.join('report.json')
      Tamoz::Evals::Benchmark::ComparisonExecutor.new(
        manifest:, protocol:, artifact_base: root
      ).write(report_path)

      assert_equal report, read_json(report_path)
      assert_equal Tamoz::Evals::CanonicalJSON.dump(report), File.read(report_path).chomp
    end
  end

  def test_cli_refuses_a_run_without_controls_and_does_not_write_a_report
    Dir.mktmpdir('benchmark-cells-refusal') do |directory|
      root = Pathname.new(directory)
      manifest = write_synthetic_run(root).merge('controls_passed' => false)
      manifest_path = root.join('manifest.json')
      File.write(manifest_path, JSON.generate(manifest))
      report_path = root.join('report.json')
      File.write(report_path, "sentinel\n")

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT.to_s,
        '--manifest', manifest_path.to_s,
        '--report-out', report_path.to_s,
        '--artifact-base', root.to_s,
        '--input-manifest', write_input_manifest(root).to_s,
        chdir: ROOT.to_s
      )

      assert_equal '', stdout
      refute_predicate status, :success?
      assert_equal 2, status.exitstatus
      assert_includes stderr, 'controls_passed must be true'
      assert_equal "sentinel\n", File.read(report_path)
    end
  end

  def test_cli_refuses_a_fixture_run_even_when_controls_are_passed
    Dir.mktmpdir('benchmark-cells-fixture-refusal') do |directory|
      root = Pathname.new(directory)
      manifest_path = root.join('manifest.json')
      File.write(manifest_path, JSON.generate(write_synthetic_run(root).merge('run_kind' => 'fixture')))
      report_path = root.join('report.json')

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT.to_s,
        '--manifest', manifest_path.to_s,
        '--report-out', report_path.to_s,
        '--artifact-base', root.to_s,
        '--input-manifest', write_input_manifest(root).to_s,
        chdir: ROOT.to_s
      )

      assert_equal 2, status.exitstatus
      assert_includes stderr, 'run_kind must be real_provider'
      refute_path_exists report_path
    end
  end

  def test_publisher_writes_report_and_appends_scoreboard_once_for_publishable_run
    Dir.mktmpdir('benchmark-publish') do |directory|
      root = Pathname.new(directory)
      manifest = write_synthetic_run(root)
      readiness = publishable_readiness(manifest)
      scoreboard_path = root.join('scoreboard.json')

      first = Tamoz::Evals::Benchmark::OpenclawPublisher.publish(
        manifest:, protocol:, readiness:, artifact_base: root, scoreboard_path:
      )
      second = Tamoz::Evals::Benchmark::OpenclawPublisher.publish(
        manifest:, protocol:, readiness:, artifact_base: root, scoreboard_path:
      )

      report_path = root.join(manifest.fetch('artifact_root'), 'report.json')

      assert_path_exists report_path
      assert_equal first.report, read_json(report_path)
      assert_predicate first.scoreboard, :appended?
      refute_predicate second.scoreboard, :appended?
      assert_equal first.scoreboard.entry, second.scoreboard.entry
      assert_equal [first.scoreboard.entry], read_json(scoreboard_path).fetch('entries')
    end
  end

  def test_publisher_refuses_an_unaccepted_run_without_writing_or_appending
    Dir.mktmpdir('benchmark-publish-refusal') do |directory|
      root = Pathname.new(directory)
      manifest = write_synthetic_run(root).merge('controls_passed' => false)
      readiness = Tamoz::Evals::Benchmark::Readiness::Result.new(
        status: 'blocked', reasons: ['controls_not_passed'], manifest:
      )
      report_path = root.join(manifest.fetch('artifact_root'), 'report.json')
      scoreboard_path = root.join('scoreboard.json')

      assert_raises(Tamoz::Evals::Benchmark::OpenclawPublisher::Refusal) do
        Tamoz::Evals::Benchmark::OpenclawPublisher.publish(
          manifest:, protocol:, readiness:, artifact_base: root, scoreboard_path:
        )
      end

      refute_path_exists report_path
      refute_path_exists scoreboard_path
    end
  end

  private

  # The cells script reads the benchmark protocol through a runner input
  # manifest whose documents must live OUTSIDE the package roots, so the
  # protocol is copied into the (external) tmpdir and descriptor'd there.
  def write_input_manifest(root)
    descriptor = lambda do |path|
      { 'path' => path.to_s, 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    protocol_path = root.join('protocol.json')
    FileUtils.cp(ROOT.join('documentation', 'benchmark', 'BENCHMARK_PROTOCOL.json'), protocol_path)
    filler = root.join('input.txt')
    File.write(filler, '{}')
    filler_descriptor = descriptor.call(filler)

    document = {
      'manifest_version' => Tamoz::Evals::Runner::InputManifest::VERSION,
      'external_root' => root.to_s,
      'corpus_definitions' => {
        'agent_smoke' => filler_descriptor, 'agent_memory' => filler_descriptor,
        'agent_memory_repository' => filler_descriptor
      },
      'scripted_model' => { 'adapter' => filler_descriptor, 'responses' => filler_descriptor },
      'mcp_server' => { 'path' => filler.to_s, 'sha256' => filler_descriptor.fetch('sha256'), 'args' => [] },
      'openclaw' => {
        'fixture_factory_loader' => filler_descriptor, 'protocol' => descriptor.call(protocol_path),
        'catalog' => filler_descriptor, 'mission' => filler_descriptor
      },
      'scenarios' => {
        'scenario_definitions' => filler_descriptor, 'sqlite_graph' => filler_descriptor,
        'limits' => filler_descriptor, 'registry' => filler_descriptor
      }
    }
    path = root.join('input-manifest.json')
    File.write(path, JSON.generate(document))
    path
  end

  def protocol
    read_json(ROOT.join('documentation', 'benchmark', 'BENCHMARK_PROTOCOL.json'))
  end

  def write_synthetic_run(root)
    artifact_root = 'real-provider/2026-08-21T120000Z-run-1'
    artifact_directory = root.join(artifact_root)
    FileUtils.mkdir_p(artifact_directory)
    artifact = {
      'mission' => {
        'id' => 'adaptive-read-only', 'family' => 'do-crash',
        'facts' => { 'dissolved_oxygen' => 1.0 }
      },
      'provenance' => {
        'provider_effect_receipts' => receipts,
        'independent_trace' => {
          'run_id' => 'run-1', 'trace' => trace
        }
      },
      'result' => {
        'terminal' => {
          'status' => 'completed', 'truth_code' => 'low_dissolved_oxygen',
          'non_truth_code' => 'unknown'
        },
        'durable_mission' => { 'run_id' => 'run-1' },
        'effect_outcomes' => [
          { 'effect_key' => 'effect-a', 'status' => 'succeeded' },
          { 'effect_key' => 'effect-b', 'status' => 'succeeded' }
        ],
        'surface_executions' => { 'cli' => { 'status' => 'executed' } }
      },
      'verification' => { 'bound_effect_keys' => %w[effect-a model-1] }
    }
    File.write(artifact_directory.join('adaptive-read-only.json'), JSON.generate(artifact))
    {
      'run_kind' => 'real_provider', 'controls_passed' => true,
      'artifact_root' => artifact_root, 'provider' => 'openrouter', 'model' => 'model-a',
      'git_revision' => 'abc123',
      'protocol_sha256' => Tamoz::Evals::Benchmark::Readiness.protocol_digest(protocol),
      'run_id' => 'run-1',
      'missions' => [{
        'id' => 'adaptive-read-only', 'family' => 'do-crash',
        'artifact_path' => 'adaptive-read-only.json',
        'surface_executions' => { 'cli' => { 'status' => 'executed' } }
      }]
    }
  end

  def publishable_readiness(manifest)
    Tamoz::Evals::Benchmark::Readiness::Result.new(
      status: 'ready', reasons: [], manifest: manifest.merge('artifacts_verified' => true)
    )
  end

  def receipts
    [
      { 'effect_key' => 'model-1', 'operation' => 'model.generate.first', 'status' => 'succeeded',
        'probabilities' => [
          { 'code' => 'low_dissolved_oxygen', 'probability' => 1 },
          { 'code' => 'unknown', 'probability' => 1 }
        ] },
      { 'effect_key' => 'model-2', 'operation' => 'model.generate.final', 'status' => 'succeeded',
        'probabilities' => [
          { 'code' => 'low_dissolved_oxygen', 'probability' => 3 },
          { 'code' => 'unknown', 'probability' => 1 }
        ] }
    ]
  end

  def trace
    {
      'trace_id' => 'trace-1',
      'spans' => [
        { 'name' => 'tamoz.tool.call', 'started_at_ms' => epoch_ms(1), 'ended_at_ms' => epoch_ms(2) },
        { 'name' => 'tamoz.decision', 'started_at_ms' => epoch_ms(3), 'ended_at_ms' => epoch_ms(4),
          'attributes' => { 'action_code' => 'low_dissolved_oxygen' } }
      ]
    }
  end

  def epoch_ms(seconds)
    Time.utc(2026, 8, 21, 12, 0, seconds).to_i * 1_000
  end

  def assert_no_floats(value)
    case value
    when Hash then value.each_value { |entry| assert_no_floats(entry) }
    when Array then value.each { |entry| assert_no_floats(entry) }
    when Float then flunk "canonical report contains float #{value.inspect}"
    end
  end
end
# rubocop:enable Style/Documentation, Minitest/MultipleAssertions
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize
