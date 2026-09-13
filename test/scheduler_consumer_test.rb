# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# P13-P (plan §8, C8) — the product consumer: a READ-ONLY scorecard summary.
# The pinned surface proof: the consumer grant contains ONLY the scorecard-run
# capability, no mutation tool; the consumer's subprocess surface is exactly
# the one deterministic scorecard invocation; delivery is never execution
# success.
class SchedulerConsumerTest < Minitest::Test
  Scheduler = Tamoz::Evals::Runner

  def test_consumer_grant_contains_no_mutation_tool
    grant = Scheduler::ScorecardSummaryConsumer.grant
    assert_equal ["read"], grant.fetch("scopes")
    assert_equal ["eval.scorecard-agent-smoke"], grant.fetch("capabilities")
    # No write/mutation surface in the allowlist (C8 pinned surface).
    refute grant.fetch("capabilities").any? { |cap| cap.include?("write") || cap.include?("patch") || cap.include?("delete") }
    refute_includes grant.fetch("scopes"), "write"
  end

  def test_consumer_runs_the_scorecard_and_extracts_the_summary
    consumer = Scheduler::ScorecardSummaryConsumer.new(
      executor: lambda do |_command|
        [true, JSON.generate(
          "decision" => "pass",
          "corpus" => { "case_count" => 20 },
          "aggregate" => { "task_successes" => 17, "unsafe_or_bypassed_actions" => 0 },
          "hard_gates" => [
            { "id" => "g1", "status" => "pass" },
            { "id" => "g2", "status" => "pass" },
            { "id" => "g3", "status" => "pass" },
            { "id" => "g4", "status" => "pass" }
          ]
        ), ""]
      end
    )
    summary = consumer.run(input_manifest: "/tmp/manifest.json")
    assert_equal true, summary.fetch("ok")
    assert_equal "pass", summary.fetch("decision")
    assert_equal 20, summary.fetch("cases")
    assert_equal 17, summary.fetch("successes")
    assert_equal 4, summary.fetch("hard_gates_passed")
    assert_equal 0, summary.fetch("unsafe_actions")
  end

  def test_consumer_fails_closed_on_nonzero_exit_and_bad_json
    failed = Scheduler::ScorecardSummaryConsumer.new(
      executor: ->(_command) { [false, "", "worker failed"] }
    ).run(input_manifest: "/tmp/manifest.json")
    assert_equal false, failed.fetch("ok")
    assert_equal "scorecard failed", failed.fetch("reason")

    bad = Scheduler::ScorecardSummaryConsumer.new(
      executor: ->(_command) { [true, "not json\n", ""] }
    ).run(input_manifest: "/tmp/manifest.json")
    assert_equal false, bad.fetch("ok")
    assert_equal "scorecard output is not JSON", bad.fetch("reason")
  end

  def test_consumer_preserves_timeout_classification
    stream = Tamoz::Evals::Harness::SubprocessRunner::Stream.new(
      '', 0, 0, false, 'sha256:empty'
    )
    result = Tamoz::Evals::Harness::SubprocessRunner::Result.new(
      ['tamoz-eval-runner'], nil, nil, true, 'timeout', 'timeout', 1, stream, stream
    )
    timed_out = Scheduler::ScorecardSummaryConsumer.new(
      executor: ->(_command) { [false, '', '', result] }
    ).run(input_manifest: '/tmp/manifest.json')

    assert_equal 'scorecard timed out', timed_out.fetch('reason')
  end

  def test_consumer_fails_closed_when_json_omits_required_summary_fields
    summary = Scheduler::ScorecardSummaryConsumer.new(
      executor: ->(_command) { [true, "{\"decision\":\"pass\"}\n", ""] }
    ).run(input_manifest: "/tmp/manifest.json")

    assert_equal false, summary.fetch("ok")
    assert_equal "scorecard report is missing required fields", summary.fetch("reason")
  end

  def test_consumer_fails_closed_when_json_root_is_not_an_object
    summary = Scheduler::ScorecardSummaryConsumer.new(
      executor: ->(_command) { [true, "[]\n", ""] }
    ).run(input_manifest: "/tmp/manifest.json")

    assert_equal false, summary.fetch("ok")
    assert_equal "scorecard report is missing required fields", summary.fetch("reason")
  end

  # The default command is `tamoz-eval-runner`. Whether that binary is
  # installed is deployment luck, so the test pins PATH to an empty directory:
  # the resolver must fail closed into the unavailable classification instead
  # of running whatever binary the developer machine happens to have.
  def test_consumer_fails_closed_when_the_scorecard_binary_is_missing
    consumer = Scheduler::ScorecardSummaryConsumer.new(input_manifest: "/tmp/manifest.json")
    summary = nil
    Dir.mktmpdir do |empty_directory|
      path_was = ENV.fetch("PATH", nil)
      ENV["PATH"] = empty_directory
      summary = consumer.run
    ensure
      path_was ? ENV["PATH"] = path_was : ENV.delete("PATH")
    end

    assert_equal false, summary.fetch("ok")
    assert_equal "scorecard command unavailable", summary.fetch("reason")
  end

  def test_default_command_requires_an_explicit_external_manifest
    summary = Scheduler::ScorecardSummaryConsumer.new.run

    assert_equal false, summary.fetch("ok")
    assert_equal "scorecard failed", summary.fetch("reason")
    assert_includes summary.fetch("stderr_tail"), "runner input manifest is required"
  end
end
