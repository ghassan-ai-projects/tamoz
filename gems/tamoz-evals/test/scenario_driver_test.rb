# frozen_string_literal: true

require_relative '../../../test/test_helper'

# Exercises the controller-owned T3 M1-to-M2 journal oracle.
class ScenarioDriverTest < Minitest::Test
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
        evidence:,
        pre_kill_effect_key: 'logical:create-file',
        restarted: true
      )

      assert_equal 0, result.fetch('metrics').fetch('recovery')
      assert_equal 'failed', result.fetch('hard_zero').fetch('duplicate_effect')
      assert_equal ['hard_zero_failed:duplicate_effect'], result.fetch('hard_zero_reasons')
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
end
