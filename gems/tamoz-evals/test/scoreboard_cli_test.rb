# frozen_string_literal: true

require_relative '../../../test/test_helper'

# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/MethodLength
# rubocop:disable Minitest/MultipleAssertions
# rubocop:disable Metrics/BlockLength
# rubocop:disable Style/Documentation
class ScoreboardCLITest < Minitest::Test
  SCOREBOARD_SCRIPT = ROOT.join('script', 'benchmark_openclaw_scoreboard')
  REGRESSION_SCRIPT = ROOT.join('script', 'benchmark_openclaw_regression')
  EXISTING_MANIFEST = Pathname.new(
    '/Users/ghassan/my-projects/.e2e-run/round-006-b1/artifacts/real-provider/20260821T141500Z-e05b1f6/manifest.json'
  )

  def test_scoreboard_command_refuses_the_existing_unaccepted_real_run
    RunnerInputs.with_manifest do |input_manifest|
      Dir.mktmpdir('scoreboard-cli') do |directory|
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, SCOREBOARD_SCRIPT.to_s,
          '--manifest', EXISTING_MANIFEST.to_s,
          '--report', Pathname.new(directory).join('does-not-exist.json').to_s,
          '--scoreboard', Pathname.new(directory).join('scoreboard.json').to_s,
          '--input-manifest', input_manifest,
          chdir: ROOT.to_s
        )

        refute_predicate status, :success?
        assert_empty stdout
        assert_includes stderr, 'controls_passed must be true'
      end
    end
  end

  def test_scoreboard_command_is_deterministic_and_idempotent
    RunnerInputs.with_manifest do |input_manifest|
      Dir.mktmpdir('scoreboard-cli') do |directory|
        root = Pathname.new(directory)
        manifest_path = write_manifest(root, artifact_root: 'real-provider/2026-08-21T120000Z-run')
        report_path = write_report(root.join('report.json'))
        scoreboard_path = root.join('scoreboard.json')
        args = [
          RbConfig.ruby, SCOREBOARD_SCRIPT.to_s,
          '--manifest', manifest_path.to_s, '--report', report_path.to_s,
          '--scoreboard', scoreboard_path.to_s, '--artifact-base', root.to_s,
          '--input-manifest', input_manifest
        ]

        first_stdout, first_stderr, first_status = Open3.capture3(*args, chdir: ROOT.to_s)
        first_bytes = scoreboard_path.binread
        second_stdout, second_stderr, second_status = Open3.capture3(*args, chdir: ROOT.to_s)

        assert_predicate first_status, :success?, first_stderr
        assert_predicate second_status, :success?, second_stderr
        assert_equal 'appended', JSON.parse(first_stdout).fetch('status')
        assert_equal 'already_present', JSON.parse(second_stdout).fetch('status')
        assert_equal first_bytes, scoreboard_path.binread
        assert_equal 1, JSON.parse(File.read(scoreboard_path)).fetch('entries').length
      end
    end
  end

  def test_regression_gate_fails_without_reviewed_note_and_passes_for_stable_values
    RunnerInputs.with_manifest do |input_manifest|
      Dir.mktmpdir('scoreboard-regression') do |directory|
        root = Pathname.new(directory)
        scoreboard_path = root.join('scoreboard.json')
        prior_root = 'real-provider/2026-08-20T120000Z-prior'
        current_root = 'real-provider/2026-08-21T120000Z-current'
        write_manifest(root, artifact_root: prior_root, score: 800)
        prior_directory = root.join(prior_root)
        FileUtils.mkdir_p(prior_directory)
        intervals = Tamoz::Evals::Benchmark::Scoreboard::AXES.to_h do |axis|
          [axis, { 'low' => 700, 'high' => 900 }]
        end
        File.write(prior_directory.join('intervals.json'), JSON.generate('axis_intervals' => intervals))

        append_entry(root, scoreboard_path, prior_root, 800)
        current_manifest = write_manifest(root, artifact_root: current_root, score: 600)
        append_entry(root, scoreboard_path, current_root, 600)

        _stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, REGRESSION_SCRIPT.to_s, '--scoreboard', scoreboard_path.to_s,
          '--manifest', current_manifest.to_s, '--artifact-base', root.to_s,
          '--input-manifest', input_manifest, chdir: ROOT.to_s
        )

        refute_predicate status, :success?
        assert_includes stderr, 'unacknowledged scoreboard regression'

        stable_scoreboard = root.join('stable.json')
        stable_current = write_manifest(root, artifact_root: 'real-provider/2026-08-21T120000Z-stable', score: 800)
        append_entry(root, stable_scoreboard, prior_root, 800)
        append_entry(root, stable_scoreboard, 'real-provider/2026-08-21T120000Z-stable', 800)
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, REGRESSION_SCRIPT.to_s, '--scoreboard', stable_scoreboard.to_s,
          '--manifest', stable_current.to_s, '--artifact-base', root.to_s,
          '--input-manifest', input_manifest, chdir: ROOT.to_s
        )

        assert_predicate status, :success?, stderr
        assert_equal 'passed', JSON.parse(stdout).fetch('status')
      end
    end
  end

  private

  def write_manifest(root, artifact_root:, score: 1_000)
    path = root.join("#{artifact_root.tr('/', '_')}-manifest.json")
    File.write(path, JSON.generate(
                       {
                         'run_kind' => 'real_provider', 'controls_passed' => true, 'artifact_root' => artifact_root,
                         'git_revision' => 'abc123', 'protocol_sha256' => "sha256:#{'a' * 64}",
                         'provider' => 'openrouter', 'model' => 'deepseek/deepseek-chat',
                         'missions' => missions(score)
                       }
                     ))
    path
  end

  def append_entry(root, scoreboard_path, artifact_root, score)
    Tamoz::Evals::Benchmark::Scoreboard.append(
      manifest: JSON.parse(File.read(write_manifest(root, artifact_root:, score:))),
      report: report,
      scoreboard_path:
    )
  end

  def write_report(path)
    File.write(path, JSON.generate(report))
    path
  end

  def report
    {
      'date' => '2026-08-21',
      'axis_verdicts' => Tamoz::Evals::Benchmark::Scoreboard::AXES.to_h { |axis| [axis, 'go'] }
    }
  end

  def missions(score)
    [
      mission('adaptive-read-only', { 'completion' => score, 'cost' => 100 }),
      mission('contradictory-observation', { 'completion' => score, 'recovery' => score, 'cost' => 100 }),
      mission('governed-mutation', { 'completion' => score, 'approval_correctness' => score, 'cost' => 100 }),
      mission('capability-availability', { 'completion' => score, 'availability_accuracy' => score, 'cost' => 100 }),
      mission('web-mcp', { 'completion' => score, 'tool_correctness' => score, 'cost' => 100 }),
      mission('compaction-restart', { 'completion' => score, 'recovery' => score, 'cost' => 100 }),
      mission('scheduled-restart', { 'completion' => score, 'recovery' => score, 'cost' => 100 }),
      mission('memory-attribution', { 'completion' => score, 'retrieval_correctness' => score, 'cost' => 100 }),
      mission('self-inspection', { 'completion' => score, 'inspection_correctness' => score, 'cost' => 100 })
    ]
  end

  def mission(id, metrics)
    { 'id' => id, 'metrics' => metrics, 'hard_zero' => {} }
  end
end
# rubocop:enable Style/Documentation
# rubocop:enable Metrics/BlockLength
# rubocop:enable Minitest/MultipleAssertions
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/AbcSize
