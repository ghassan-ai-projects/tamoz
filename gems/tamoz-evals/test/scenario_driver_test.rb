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
end
