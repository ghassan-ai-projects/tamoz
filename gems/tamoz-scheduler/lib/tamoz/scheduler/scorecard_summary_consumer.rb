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
      # :reek:UncommunicativeVariableName -- `e` is the rescue-variable name the
      # linter enforces repository-wide.
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

        summary = {
          "ok" => true,
          "decision" => report["decision"],
          "cases" => report.dig("corpus", "case_count"),
          "successes" => report.dig("aggregate", "task_successes"),
          "hard_gates_passed" => nil,
          "hard_gates_total" => nil,
          "unsafe_actions" => report.dig("aggregate", "unsafe_or_bypassed_actions")
        }
        gates = report["hard_gates"]
        if gates.is_a?(Array)
          summary["hard_gates_passed"] = gates.count { |g| g.is_a?(Hash) && g["status"] == "pass" }
          summary["hard_gates_total"] = gates.length
        end
        # Fail closed on a report that is valid JSON but structurally wrong
        # (missing decision/gates): a summary with nil gate counts is not a
        # usable execution-success signal.
        return {"ok" => false, "reason" => "scorecard report is missing required fields"} \
          if summary["decision"].nil? || summary["hard_gates_total"].nil?

        summary
      rescue SystemCallError => e
        # The binary is not on PATH, or is not executable. Every other failure
        # in this method is a fail-closed hash; a missing command is no
        # different, and letting Errno::ENOENT escape would make it the one
        # failure mode that takes the consumer's caller down with it.
        {"ok" => false, "reason" => "scorecard command unavailable",
         "stderr_tail" => e.message.byteslice(0, 4_096)}
      end

      def self.grant = READ_ONLY_GRANT
    end
  end
end
