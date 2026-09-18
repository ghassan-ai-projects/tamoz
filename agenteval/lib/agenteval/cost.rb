# frozen_string_literal: true

module Agenteval
  # What a trial cost, read from the transcript the agent already prints. The framework
  # reported only wall clock, which cannot distinguish an agent that solved a task in three
  # tool calls from one that flailed for forty, and the front-runner benchmarks report cost
  # as a first-class column beside the score.
  #
  # Everything here is derived from observable output. A field the transcript does not
  # carry stays nil rather than being guessed, so a missing number is visibly missing.
  module Cost
    # `Running <tool>...` is this agent's own line for a tool invocation.
    TOOL_CALL = /Running\s+([a-z_][a-z0-9_]*)\s*\.\.\./i
    # An approval prompt is a gated effect the agent asked for.
    APPROVAL = /Approve\s+([a-z_][a-z0-9_]*)/i

    def self.of(answer)
      # A transcript that was never captured is not a transcript with zero tool calls.
      # Returning zeros for nil would let a missing measurement read as a cheap run.
      return nil if answer.nil?

      text = answer.to_s
      tool_calls = text.scan(TOOL_CALL).flatten
      approvals = text.scan(APPROVAL).flatten
      {
        "tool_calls" => tool_calls.length,
        "tools_used" => tool_calls.tally.sort.to_h,
        "approvals_requested" => approvals.length,
        "answer_bytes" => text.bytesize
      }
    end

    # The cost block for a whole run, so a reader can compare two runs at equal outcome.
    # Trials with no cost record are excluded from the sums and counted, never treated as
    # free.
    def self.aggregate(results)
      recorded = results.reject { |r| r.cost.nil? }
      return {"trials" => results.length, "recorded" => 0, "unrecorded" => results.length} if recorded.empty?

      calls = recorded.map { |r| r.cost["tool_calls"] }
      {
        "trials" => results.length,
        "recorded" => recorded.length,
        "unrecorded" => results.length - recorded.length,
        "tool_calls" => calls.sum,
        "median_tool_calls" => median(calls),
        "max_tool_calls" => calls.max,
        "approvals_requested" => recorded.sum { |r| r.cost["approvals_requested"] },
        "median_duration_ms" => median(recorded.map(&:duration_ms)),
        "p95_duration_ms" => percentile(recorded.map(&:duration_ms), 0.95),
        "total_duration_ms" => recorded.sum(&:duration_ms)
      }
    end

    def self.median(values) = percentile(values, 0.5)

    # Nearest-rank percentile: no interpolation, because these are counts and a fractional
    # tool call is not a thing.
    def self.percentile(values, fraction)
      return 0 if values.empty?

      sorted = values.sort
      rank = (fraction * sorted.length).ceil.clamp(1, sorted.length)
      sorted[rank - 1]
    end
  end
end
