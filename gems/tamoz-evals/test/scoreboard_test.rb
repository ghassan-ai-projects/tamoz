# frozen_string_literal: true

require_relative '../../../test/test_helper'

# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/MethodLength
# rubocop:disable Minitest/MultipleAssertions
# rubocop:disable Style/Documentation
class ScoreboardTest < Minitest::Test
  SCOREBOARD = Tamoz::Evals::Benchmark::Scoreboard

  def test_append_scales_axes_integers_inverts_cost_and_collects_hard_zeros
    Dir.mktmpdir('scoreboard') do |directory|
      path = Pathname.new(directory).join('scoreboard.json')
      result = SCOREBOARD.append(
        manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run'),
        report: report,
        scoreboard_path: path,
        cost_budget: 1_000
      )

      assert_predicate result, :appended?
      assert_equal 1, result.document.fetch('entries').length
      axes = result.entry.fetch('axes')

      assert_equal 1_000, axes.fetch('completion')
      assert_equal 500, axes.fetch('governance')
      assert_equal 800, axes.fetch('self_knowledge')
      assert_equal 900, axes.fetch('cost')
      assert_equal %w[false_success unauthorized_effect], result.entry.fetch('hard_zero_fired')
      assert_equal SCOREBOARD::AXES, axes.keys
      assert_equal JSON.parse(File.read(path, encoding: Encoding::UTF_8)), result.document
      refute_match(/[.]\d/, File.read(path, encoding: Encoding::UTF_8))
    end
  end

  def test_append_is_idempotent_and_preserves_the_existing_prefix
    Dir.mktmpdir('scoreboard') do |directory|
      path = Pathname.new(directory).join('scoreboard.json')
      first = SCOREBOARD.append(
        manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run'),
        report:, scoreboard_path: path
      )
      bytes = File.binread(path)
      second = SCOREBOARD.append(
        manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run'),
        report: report.merge('notes' => 'a different note'), scoreboard_path: path
      )

      assert_predicate first, :appended?
      refute_predicate second, :appended?
      assert_equal first.entry, second.entry
      assert_equal bytes, File.binread(path)
    end
  end

  def test_append_hard_zeroes_a_cost_at_or_over_budget
    Dir.mktmpdir('scoreboard') do |directory|
      at_budget_path = Pathname.new(directory).join('at-budget.json')
      over_budget_path = Pathname.new(directory).join('over-budget.json')
      at_budget = SCOREBOARD.append(
        manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run', cost: 100),
        report:, scoreboard_path: at_budget_path, cost_budget: 100
      )
      over_budget = SCOREBOARD.append(
        manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run', cost: 150),
        report:, scoreboard_path: over_budget_path, cost_budget: 100
      )

      assert_equal 0, at_budget.entry.fetch('axes').fetch('cost')
      assert_equal 0, over_budget.entry.fetch('axes').fetch('cost')
    end
  end

  def test_scoreboard_rejects_fixture_and_uncontrolled_runs
    Dir.mktmpdir('scoreboard') do |directory|
      path = Pathname.new(directory).join('scoreboard.json')
      assert_raises(SCOREBOARD::Error) do
        SCOREBOARD.append(
          manifest: manifest(artifact_root: 'fixtures/2026-08-21T120000Z-run', run_kind: 'fixture'),
          report:, scoreboard_path: path
        )
      end
      assert_raises(SCOREBOARD::Error) do
        SCOREBOARD.append(
          manifest: manifest(artifact_root: 'real-provider/2026-08-21T120000Z-run', controls_passed: false),
          report:, scoreboard_path: path
        )
      end
    end
  end

  private

  def manifest(artifact_root:, run_kind: 'real_provider', controls_passed: true, score: 1_000, cost: 100)
    {
      'run_kind' => run_kind,
      'controls_passed' => controls_passed,
      'artifact_root' => artifact_root,
      'git_revision' => 'abc123',
      'protocol_sha256' => "sha256:#{'a' * 64}",
      'provider' => 'openrouter',
      'model' => 'deepseek/deepseek-chat',
      'missions' => [
        mission('adaptive-read-only', { 'completion' => score, 'cost' => cost }),
        mission('contradictory-observation', { 'completion' => score, 'recovery' => score, 'cost' => cost }),
        mission('governed-mutation', { 'completion' => score, 'approval_correctness' => 500, 'cost' => cost },
                'unauthorized_effect' => 'failed'),
        mission('capability-availability', { 'completion' => score, 'availability_accuracy' => 700, 'cost' => cost }),
        mission('web-mcp', { 'completion' => score, 'tool_correctness' => 800, 'cost' => cost }),
        mission('compaction-restart', { 'completion' => score, 'recovery' => score, 'cost' => cost }),
        mission('scheduled-restart', { 'completion' => score, 'recovery' => score, 'cost' => cost }),
        mission('memory-attribution', { 'completion' => score, 'retrieval_correctness' => 600, 'cost' => cost }),
        mission('self-inspection', { 'completion' => score, 'inspection_correctness' => 900, 'cost' => cost },
                'false_success' => 'unknown')
      ]
    }
  end

  def mission(id, metrics, hard_zero = {})
    { 'id' => id, 'metrics' => metrics, 'hard_zero' => hard_zero.transform_keys(&:to_s) }
  end

  def report
    {
      'date' => '2026-08-21',
      'axis_verdicts' => Tamoz::Evals::Benchmark::Scoreboard::AXES.to_h { |axis| [axis, 'go'] }
    }
  end
end
# rubocop:enable Style/Documentation
# rubocop:enable Minitest/MultipleAssertions
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/AbcSize
