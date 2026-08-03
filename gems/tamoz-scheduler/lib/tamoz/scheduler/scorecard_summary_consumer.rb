# frozen_string_literal: true

require "open3"
require "json"

module Tamoz
  module Scheduler
    # P13-P (plan §8) — the one safe recurring product task: a READ-ONLY
    # scorecard summary. The consumer reruns the deterministic agent-smoke
    # scorecard and emits a summary through the ordinary delivery policy.
    #
    # Pinned surface (C8): the grant for this consumer contains ONLY the
    # scorecard-run capability (the `tamoz-eval scorecard agent-smoke`
    # subprocess invocation), NO mutation tools; risk class is read-only; the
    # approval policy is deterministic and read-only-only; delivery is ordinary
    # and never reported as execution success (the occurrence's enqueued state
    # is delivery, not execution).
    #
    # The consumer is deliberately tiny and dependency-light: it runs one
    # subprocess, validates the JSON report shape, and returns a summary
    # hash. Everything else (durability, dedup, grant intersection) is the
    # ScheduleStore's job.
    class ScorecardSummaryConsumer
      READ_ONLY_GRANT = {
        "scopes" => ["read"],
        "capabilities" => ["eval.scorecard-agent-smoke"]
      }.freeze

      # The only approved operation: run the deterministic scorecard, read the
      # report, return a summary. `allowlist` is asserted by the consumer
      # grant-allowlist test — this surface has NO mutation tool.
      def run(scorecard_command: nil)
        command = scorecard_command || ["tamoz-eval", "scorecard", "agent-smoke"]
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          return {
            "ok" => false,
            "reason" => "scorecard failed",
            "stderr_tail" => stderr.to_s.byteslice(0, 4_096)
          }
        end

        begin
          report = JSON.parse(stdout)
        rescue JSON::ParserError
          return {"ok" => false, "reason" => "scorecard output is not JSON"}
        end

        {
          "ok" => true,
          "decision" => report.fetch("decision"),
          "cases" => report.dig("corpus", "case_count"),
          "successes" => report.dig("aggregate", "task_successes"),
          "hard_gates_passed" => report.fetch("hard_gates").count { |g| g.fetch("status") == "pass" },
          "hard_gates_total" => report.fetch("hard_gates").length,
          "unsafe_actions" => report.dig("aggregate", "unsafe_or_bypassed_actions")
        }
      end

      def self.grant = READ_ONLY_GRANT
    end
  end
end
