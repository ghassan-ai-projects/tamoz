# frozen_string_literal: true

module Agenteval
  module SubagentPack
    # The pack report (EVAL.md §3): per-arm results, hard gates, delegation by tag, cost, repetition and MAST labels.
    module Report
      HARD_GATES = %w[child_write leak tests_deleted].freeze

      module_function

      def build(rows, arms:, repeat:, window:)
        {
          "report_type" => "agenteval.subagent_pack", "generated_at" => Time.now.utc.iso8601,
          "provider" => TamozCode.provider, "model" => TamozCode.provider_model, "repeat" => repeat,
          "window" => window || "route default",
          "evidence" => "Trials are real-model results. The graders were proven offline by `agenteval subagents " \
                        "prove` (controls: #{CONTROLS.keys.join(', ')}); no control result is a model result.",
          "limits" => ["#{rows.map { |row| row['scenario'] }.uniq.length} scenarios: every arm difference is a " \
                       "finding, not a significance claim"],
          "arms" => arms.to_h { |arm| [arm, summary(rows.select { |row| row["arm"] == arm })] },
          "g3_trivial_token_ratio" => trivial_ratio(rows),
          "trials" => rows
        }
      end

      def summary(rows)
        by_scenario = rows.group_by { |row| row["scenario"] }
        solved = by_scenario.count { |_, trials| trials.all? { |row| row["solved"] } }
        { "pass_k" => solved, "scenarios" => by_scenario.length, "interval" => wilson(solved, by_scenario.length),
          "solved_trials" => rows.count { |row| row["solved"] }, "trials" => rows.length,
          "inconclusive" => Graders.inconclusive?(rows),
          "hard_gate_trips" => HARD_GATES.to_h { |gate| [gate, rows.count { |row| row["gates"].include?(gate) }] },
          "gate_trips" => rows.flat_map { |row| row["gates"] }.tally,
          "delegation_rate_by_tag" => rows.group_by { |row| row["tag"] }.transform_values do |trials|
            trials.count { |row| row["delegations"].to_i.positive? }.fdiv(trials.length).round(3)
          end,
          "trivial_trials_delegating" => rows.count { |row| row["tag"] == "trivial" && row["delegations"].to_i.positive? },
          "repetition_mean" => mean(rows.filter_map { |row| row["repetition"] }),
          "tokens" => tokens(rows), "compactions" => rows.sum { |row| row["compactions"].to_i },
          "parent_peak_prompt_tokens_p50_p95" => percentiles(rows.map { |row| row["parent_peak_prompt_tokens"].to_i }),
          "per_solved_scenario" => per_solved(rows, solved),
          "per_scenario" => by_scenario.transform_values { |trials| trials.map { |row| row["solved"] } },
          "mast" => mast(rows) }
      end

      def total(row) = %w[parent_prompt_tokens parent_completion_tokens child_prompt_tokens child_completion_tokens]
                       .sum { |field| row[field].to_i }

      def tokens(rows)
        { "parent_p50_p95" => percentiles(rows.map { |row| row["parent_prompt_tokens"].to_i + row["parent_completion_tokens"].to_i }),
          "children_p50_p95" => percentiles(rows.map { |row| row["child_prompt_tokens"].to_i + row["child_completion_tokens"].to_i }),
          "total_p50_p95" => percentiles(rows.map { |row| total(row) }), "total" => rows.sum { |row| total(row) } }
      end

      def per_solved(rows, solved)
        return nil if solved.zero?

        { "tokens" => rows.sum { |row| total(row) } / solved,
          "wall_seconds" => rows.sum { |row| row["duration_ms"].to_i } / 1000 / solved }
      end

      # Failure modes the record shows by itself; everything else about a failure is read from the trial.
      def mast(rows)
        failed = rows.reject { |row| row["solved"] }
        { "step_repetition" => failed.count { |row| row["repetition"].to_f > Graders::REPETITION_LIMIT },
          "premature_termination" => failed.count { |row| Array(row["child_statuses"]).include?("handed_off") },
          "false_success" => failed.count { |row| row["exit_code"].to_i.zero? && !row["exit_code"].nil? },
          "failed_trials" => failed.length }
      end

      def trivial_ratio(rows)
        spent = %w[subagents-on subagents-off].to_h do |arm|
          [arm, rows.select { |row| row["arm"] == arm && row["tag"] == "trivial" }.sum { |row| total(row) }]
        end
        off = spent.fetch("subagents-off")
        off.zero? ? nil : spent.fetch("subagents-on").fdiv(off).round(3)
      end

      def mean(values) = values.empty? ? nil : (values.sum.to_f / values.length).round(3)

      def percentiles(values)
        sorted = values.sort
        return [nil, nil] if sorted.empty?

        [0.5, 0.95].map { |fraction| sorted[((sorted.length - 1) * fraction).round] }
      end

      def wilson(successes, count, z = 1.96)
        return nil if count.zero?

        phat = successes.fdiv(count)
        centre = phat + (z * z / (2 * count))
        margin = z * Math.sqrt(((phat * (1 - phat)) + (z * z / (4 * count))) / count)
        denominator = 1 + (z * z / count)
        [((centre - margin) / denominator).round(3), ((centre + margin) / denominator).round(3)]
      end
    end
  end
end
