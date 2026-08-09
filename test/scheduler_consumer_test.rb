# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# P13-P (plan §8, C8) — the product consumer: a READ-ONLY scorecard summary.
# The pinned surface proof: the consumer grant contains ONLY the scorecard-run
# capability, no mutation tool; the consumer's subprocess surface is exactly
# the one deterministic scorecard invocation; delivery is never execution
# success.
class SchedulerConsumerTest < Minitest::Test
  Scheduler = Tamoz::Scheduler

  def test_consumer_grant_contains_no_mutation_tool
    grant = Scheduler::ScorecardSummaryConsumer.grant
    assert_equal ["read"], grant.fetch("scopes")
    assert_equal ["eval.scorecard-agent-smoke"], grant.fetch("capabilities")
    # No write/mutation surface in the allowlist (C8 pinned surface).
    refute grant.fetch("capabilities").any? { |cap| cap.include?("write") || cap.include?("patch") || cap.include?("delete") }
    refute_includes grant.fetch("scopes"), "write"
  end

  def test_consumer_runs_the_scorecard_and_extracts_the_summary
    consumer = Scheduler::ScorecardSummaryConsumer.new
    stub = File.join(Dir.mktmpdir("tamoz-consumer"), "stub")
    File.write(stub, <<~RUBY, encoding: Encoding::UTF_8)
      require "json"
      puts JSON.generate({
        "decision" => "pass",
        "corpus" => {"case_count" => 20},
        "aggregate" => {"task_successes" => 17, "unsafe_or_bypassed_actions" => 0},
        "hard_gates" => [
          {"id" => "g1", "status" => "pass"},
          {"id" => "g2", "status" => "pass"},
          {"id" => "g3", "status" => "pass"},
          {"id" => "g4", "status" => "pass"}
        ]
      })
    RUBY
    summary = consumer.run(scorecard_command: [RbConfig.ruby, stub])
    assert_equal true, summary.fetch("ok")
    assert_equal "pass", summary.fetch("decision")
    assert_equal 20, summary.fetch("cases")
    assert_equal 17, summary.fetch("successes")
    assert_equal 4, summary.fetch("hard_gates_passed")
    assert_equal 0, summary.fetch("unsafe_actions")
  end

  def test_consumer_fails_closed_on_nonzero_exit_and_bad_json
    consumer = Scheduler::ScorecardSummaryConsumer.new

    failed = consumer.run(scorecard_command: [RbConfig.ruby, "-e", "exit 3"])
    assert_equal false, failed.fetch("ok")
    assert_equal "scorecard failed", failed.fetch("reason")

    bad = consumer.run(scorecard_command: [RbConfig.ruby, "-e", "puts 'not json'"])
    assert_equal false, bad.fetch("ok")
    assert_equal "scorecard output is not JSON", bad.fetch("reason")
  end

  # The default command is `tamoz-eval`, which is not on PATH in every
  # deployment. `Open3.capture3` answers that with Errno::ENOENT — the one
  # failure in this method that used to escape as an exception while every
  # other one returned a fail-closed hash.
  def test_consumer_fails_closed_when_the_scorecard_binary_is_missing
    summary = Scheduler::ScorecardSummaryConsumer.new.run(
      scorecard_command: ["definitely-not-a-real-binary-8f3a", "scorecard"]
    )

    assert_equal false, summary.fetch("ok")
    assert_equal "scorecard command unavailable", summary.fetch("reason")
  end
end
