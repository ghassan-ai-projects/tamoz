# frozen_string_literal: true

require_relative '../../../test/test_helper'

# Exercises the controller-owned T3 M1-to-M2 journal oracle.
class ScenarioDriverTest < Minitest::Test
  # Records the durable seams needed to exercise restart setup without a provider.
  class RestartAdapter
    attr_reader :worker_until_effect_calls, :worker_subprocess_calls, :workspace, :enqueued_tasks

    def initialize(workspace)
      @workspace = workspace
      @worker_until_effect_calls = 0
      @worker_subprocess_calls = 0
      @enqueued_tasks = []
    end

    def prepare!(**); end

    def prepare_changes!; end

    def prepare_scenario!(scenario:, restart:)
      return unless restart

      path = File.join(workspace, scenario.fetch('setup').fetch('fixture').fetch('path'))
      FileUtils.mkdir_p(File.dirname(path))
      if File.file?(path) && !File.symlink?(path) &&
         File.binread(path) == scenario.fetch('setup').fetch('fixture').fetch('content')
        File.delete(path)
      end
      return unless File.exist?(path) || File.symlink?(path)

      raise Tamoz::Evals::ExecutionError, 'restart_fixture_already_exists'
    end

    def prepare_step!(**); end

    def post_contradiction_digest(**)
      raise 'not used by the restart scenario'
    end

    def stale_value(**)
      raise 'not used by the restart scenario'
    end

    def restart_task(scenario:, step:, goal:)
      arguments = JSON.generate(scenario.fetch('setup').fetch('fixture'))
      "#{goal}\n\n#{step.fetch('task')} Use these exact create_file arguments: #{arguments}."
    end

    def result_for(**)
      { 'status' => 'ready' }
    end

    def evidence_for(**)
      receipts = [
        {
          'effect_key' => 'logical:create-file',
          'logical_key' => 'logical:create-file',
          'operation' => 'tool.create_file',
          'status' => 'succeeded'
        }
      ]
      {
        'status' => 'completed',
        'terminal' => { 'satisfied' => true },
        'verification' => {
          'terminal_reason' => 'adaptive_final',
          'satisfied' => true,
          'evidence' => ['observation:restart']
        },
        'effect_receipts_complete' => true,
        'effect_receipts' => receipts,
        'effect_receipt_history' => receipts
      }
    end

    def thread_id_for(mission_id)
      "thread:#{mission_id}"
    end

    def enqueue!(_thread, task, **)
      @enqueued_tasks << task
    end

    def worker!; end

    def worker_until_effect!(**)
      @worker_until_effect_calls += 1
      path = File.join(workspace, ScenarioDriverInputs.restart_fixture_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, ScenarioDriverInputs.restart_fixture_content)
      'logical:create-file'
    end

    def worker_subprocess!(**)
      @worker_subprocess_calls += 1
    end
  end

  def test_recovery_scores_when_the_journal_contains_the_corrected_reread_and_terminal_cites_it
    Dir.mktmpdir('scenario-driver') do |directory|
      digest = write_fixture(directory, 'inactive')
      result = oracle(
        digest:,
        answer: 'The corrected status is inactive.',
        verification_refs: %w[observation:0 observation:1]
      )

      assert_equal 1_000, result.fetch('metrics').fetch('recovery')
      assert_equal 'passed', result.fetch('hard_zero').fetch('false_success')
    end
  end

  def test_false_success_fails_when_the_terminal_cites_the_stale_value
    Dir.mktmpdir('scenario-driver') do |directory|
      digest = write_fixture(directory, 'inactive')
      result = oracle(
        digest:,
        answer: 'The status is active.',
        verification_refs: %w[observation:0 observation:1]
      )

      assert_equal 'failed', result.fetch('hard_zero').fetch('false_success')
      assert_equal ['hard_zero_failed:false_success'], result.fetch('hard_zero_reasons')
    end
  end

  def test_false_success_is_unknown_when_terminal_evidence_is_insufficient
    result = Tamoz::Evals::Benchmark::ScenarioDriver.oracle(
      scenario_id: 'T3-m1m2',
      scenario_definitions: ScenarioDriverInputs.definitions,
      evidence: { 'effect_receipts' => [], 'verification' => {} },
      post_contradiction_digest: 'f' * 64,
      stale_value: 'active',
      second_observation_ref: 'observation:1'
    )

    assert_equal 0, result.fetch('metrics').fetch('recovery')
    assert_equal 'unknown', result.fetch('hard_zero').fetch('false_success')
    assert_equal ['hard_zero_unverifiable:false_success'], result.fetch('hard_zero_reasons')
  end

  def test_compaction_restart_oracle_scores_clean_kill_and_resume
    Dir.mktmpdir('scenario-restart-oracle') do
      evidence = restart_evidence(restarted_receipts)
      result = Tamoz::Evals::Benchmark::ScenarioDriver.oracle(
        scenario_id: 'T3-m3m4',
        scenario_definitions: ScenarioDriverInputs.definitions,
        evidence:,
        pre_kill_effect_key: 'logical:create-file',
        restarted: true
      )

      assert_equal 1_000, result.fetch('metrics').fetch('recovery')
      assert_equal 0, result.fetch('metrics').fetch('duplicate_effect_rate')
      assert_equal 'passed', result.fetch('hard_zero').fetch('duplicate_effect')
    end
  end

  def test_compaction_restart_oracle_fails_on_a_rejournaled_logical_key
    Dir.mktmpdir('scenario-restart-oracle') do
      receipts = restarted_receipts
      evidence = restart_evidence(receipts + [receipts.fetch(1)])
      result = Tamoz::Evals::Benchmark::ScenarioDriver.oracle(
        scenario_id: 'T3-m3m4',
        scenario_definitions: ScenarioDriverInputs.definitions,
        evidence:,
        pre_kill_effect_key: 'logical:create-file',
        restarted: true
      )

      assert_equal 0, result.fetch('metrics').fetch('recovery')
      assert_equal 'failed', result.fetch('hard_zero').fetch('duplicate_effect')
      assert_equal ['hard_zero_failed:duplicate_effect'], result.fetch('hard_zero_reasons')
    end
  end

  def test_compaction_restart_reuses_its_fixture_and_reaches_the_kill_seam_twice
    Dir.mktmpdir('scenario-restart-driver') do |workspace|
      adapter = RestartAdapter.new(workspace)
      driver = restart_driver(adapter)

      results = Array.new(2) { driver.call(**restart_call_arguments) }
      statuses = results.map { |result| result.fetch('status') }

      assert_equal(
        [%w[ready ready], 2, 2,
         ScenarioDriverInputs.restart_fixture_content],
        [statuses, adapter.worker_until_effect_calls,
         adapter.worker_subprocess_calls, File.binread(restart_fixture_path(workspace))]
      )
    end
  end

  def test_compaction_restart_task_contains_one_stable_create_file_request
    Dir.mktmpdir('scenario-restart-task') do |workspace|
      adapter = RestartAdapter.new(workspace)

      restart_driver(adapter).call(**restart_call_arguments)

      task = adapter.enqueued_tasks.first
      arguments = JSON.generate(
        'path' => ScenarioDriverInputs.restart_fixture_path,
        'content' => ScenarioDriverInputs.restart_fixture_content,
        'expected_sha256' => ScenarioDriverInputs.restart_fixture_digest,
        'mode' => ScenarioDriverInputs.restart_fixture_mode
      )

      assert_equal 1, task.scan(arguments).length
      assert_includes task, 'durable checkpoint'
      assert_includes task, 'without re-journaling the effect'
      assert_includes task, "Use these exact create_file arguments: #{arguments}."
      refute_includes task, 'read that file back'
      refute_includes task, 'pending fixture'
    end
  end

  def test_compaction_restart_m4_task_describes_journaled_recovery
    steps = Tamoz::Evals::Benchmark::ScenarioDriver.definition(
      'T3-m3m4', scenario_definitions: ScenarioDriverInputs.definitions
    ).fetch('steps')
    task = steps.fetch(1).fetch('task')

    assert_includes task, 'durable checkpoint'
    assert_includes task, 'journaled create_file result'
    assert_includes task, 'Do not re-journal the effect'
    assert_includes task, 'summarize the recovery'
    refute_includes task, 'pending fixture'
    refute_includes task, 'second bounded fixture'
  end

  def test_compaction_restart_keeps_an_unknown_fixture_and_blocks
    Dir.mktmpdir('scenario-restart-driver') do |workspace|
      original = "user-owned content\n"
      path = write_restart_fixture(workspace, original)
      adapter = RestartAdapter.new(workspace)

      result = restart_driver(adapter).call(**restart_call_arguments)

      assert_equal(
        %w[blocked restart_fixture_already_exists] + [original, 0],
        [result.fetch('status'), result.fetch('reason'), File.binread(path),
         adapter.worker_until_effect_calls]
      )
    end
  end

  def test_compaction_restart_keeps_a_symlink_at_the_fixture_path_and_blocks
    Dir.mktmpdir('scenario-restart-driver') do |workspace|
      path, target = symlink_restart_fixture(workspace)
      adapter = RestartAdapter.new(workspace)

      result = restart_driver(adapter).call(**restart_call_arguments)

      assert_equal(
        %w[blocked restart_fixture_already_exists true true 0],
        [result.fetch('status'), result.fetch('reason'), File.symlink?(path).to_s,
         File.exist?(target).to_s, adapter.worker_until_effect_calls.to_s]
      )
    end
  end

  private

  def write_fixture(directory, status)
    content = "#{JSON.generate('status' => status)}\n"
    File.binwrite(File.join(directory, 'status.json'), content)
    Digest::SHA256.hexdigest(content)
  end

  def oracle(digest:, answer:, verification_refs:)
    Tamoz::Evals::Benchmark::ScenarioDriver.oracle(
      scenario_id: 'T3-m1m2',
      scenario_definitions: ScenarioDriverInputs.definitions,
      evidence: {
        'effect_receipts' => [
          read_receipt('active'),
          read_receipt('inactive')
        ],
        'observation_refs' => %w[observation:0 observation:1],
        'verification' => { 'answer' => answer, 'evidence' => verification_refs },
        'terminal' => { 'answer' => answer, 'satisfied' => true }
      },
      post_contradiction_digest: digest,
      stale_value: 'active',
      second_observation_ref: 'observation:1'
    )
  end

  def read_receipt(status)
    content = "#{JSON.generate('status' => status)}\n"
    {
      'effect_key' => "read-#{status}",
      'operation' => 'tool.local:read_file',
      'status' => 'succeeded',
      'result' => {
        'output' => "File: scenario/status.json\nsha256: #{Digest::SHA256.hexdigest(content)}\ncontent:\n#{content}"
      }
    }
  end

  def restarted_receipts
    [
      {
        'effect_key' => 'logical:model',
        'logical_key' => 'logical:model',
        'operation' => 'model.generate.adaptive_decide',
        'status' => 'succeeded'
      },
      {
        'effect_key' => 'logical:create-file',
        'logical_key' => 'logical:create-file',
        'operation' => 'tool.create_file',
        'status' => 'succeeded'
      }
    ]
  end

  def restart_evidence(receipts)
    {
      'status' => 'completed',
      'terminal' => { 'satisfied' => true },
      'verification' => {
        'terminal_reason' => 'adaptive_final',
        'satisfied' => true,
        'evidence' => ['observation:restart']
      },
      'effect_receipts_complete' => true,
      'effect_receipts' => receipts,
      'effect_receipt_history' => receipts
    }
  end

  def restart_driver(adapter)
    Tamoz::Evals::Benchmark::ScenarioDriver.new(
      adapter:, scenario: 'T3-m3m4', scenario_definitions: ScenarioDriverInputs.definitions
    )
  end

  def restart_call_arguments
    {
      mission: {
        'id' => ScenarioDriverInputs.restart_mission_id,
        'goal' => 'Complete the restart scenario.'
      },
      run_kind: 'real_provider',
      provider: 'openrouter',
      model: 'deepseek/deepseek-chat'
    }
  end

  def restart_fixture_path(workspace)
    File.join(workspace, ScenarioDriverInputs.restart_fixture_path)
  end

  def write_restart_fixture(workspace, content)
    path = restart_fixture_path(workspace)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def symlink_restart_fixture(workspace)
    path = restart_fixture_path(workspace)
    target = File.join(workspace, 'user-owned-restart-marker.json')
    File.binwrite(target, ScenarioDriverInputs.restart_fixture_content)
    FileUtils.mkdir_p(File.dirname(path))
    File.symlink(target, path)
    [path, target]
  end
end
