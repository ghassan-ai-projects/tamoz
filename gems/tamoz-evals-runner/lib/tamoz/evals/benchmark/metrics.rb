# frozen_string_literal: true

require "time"

module Tamoz
  module Evals
    module Benchmark
      # P7 (docs/new-design/PHASE_P7_BENCHMARK.md): the frozen metric
      # functions. Pure and deterministic — the same cells re-scored anywhere
      # yield the same numbers, which is what makes the go rule's "offline
      # reproducibility" check meaningful. The definitions are the protocol's
      # (BENCHMARK_PROTOCOL.json scoring section); a change here is a NEW
      # benchmark version, not an edit.
      module Metrics
        module_function

        # Macro-averaged F1 over the diagnosis codes: per-code precision and
        # recall, averaged across codes, so a code the model never predicts
        # correctly cannot be hidden by the majority code's score.
        def macro_f1(cells, codes)
          mean(codes.map { |code| f1(confusion(cells, code)) })
        end

        # Mean recall over the diagnosis codes (per-code true-positive rate).
        def balanced_accuracy(cells, codes)
          mean(codes.map { |code| recall(confusion(cells, code)) })
        end

        # Mean squared error over the FULL probability vector: penalizes
        # overconfidence on every code, not just the primary.
        def brier(cells, codes)
          mean(cells.map do |cell|
            probabilities = normalized(cell.fetch("probabilities"), codes)
            truth = one_hot(cell.fetch("truth_code"), codes)
            codes.sum { |code| (probabilities[code] - truth[code])**2 } / codes.length.to_f
          end)
        end

        # Negative log likelihood over the FULL probability vector, floored so
        # a single zero-probability miss does not send the mean to infinity.
        def log_loss(cells, codes, floor: 1e-9)
          mean(cells.map do |cell|
            probability = normalized(cell.fetch("probabilities"), codes)
                            .fetch(cell.fetch("truth_code"))
            -Math.log([probability, floor].max)
          end)
        end

        # Expected calibration error over the primary-code probabilities:
        # binned mean-confidence vs empirical-accuracy gap.
        def calibration(cells, codes, bins: 10)
          return 0.0 if cells.empty?

          rows = calibration_rows(cells, codes)
          bin_edges = (0..bins).map { |i| i / bins.to_f }
          (0...bins).sum do |index|
            low, high = bin_edges[index], bin_edges[index + 1]
            members = rows.select do |confidence, _|
              confidence >= low && (index == bins - 1 ? confidence <= high : confidence < high)
            end
            next 0.0 if members.empty?

            mean_confidence = mean(members.map(&:first))
            accuracy = mean(members.map { |_, correct| correct ? 1.0 : 0.0 })
            (members.length / rows.length.to_f) * (mean_confidence - accuracy).abs
          end
        end

        # Coverage vs risk under abstention: for a confidence threshold sweep,
        # the fraction of cells the model commits to (coverage) and the
        # error rate on the committed subset (risk). A well-calibrated model
        # abstains where it is wrong.
        def risk_coverage(cells, codes, thresholds: [0.5, 0.6, 0.7, 0.8, 0.9])
          return [] if cells.empty?

          thresholds.map do |threshold|
            committed = cells.select do |cell|
              normalized(cell.fetch("probabilities"), codes)
                .fetch(cell.fetch("primary_code")) >= threshold
            end
            {
              "threshold" => threshold,
              "coverage" => committed.length / cells.length.to_f,
              "risk" => committed.empty? ? 0.0 :
                committed.count { |cell| cell.fetch("primary_code") != cell.fetch("truth_code") } /
                committed.length.to_f
            }
          end
        end

        # Hard zero gate: any cited reference outside the frame's fact ids is
        # a fabricated reference. The protocol freezes the rate at zero.
        def fabricated_reference_rate(cells)
          return 0.0 if cells.empty?

          fabricated = cells.sum do |cell|
            (Array(cell.fetch("evidence_refs")) - Array(cell.fetch("valid_evidence_ids"))).length
          end
          fabricated / cells.length.to_f
        end

        # Decision time minus the first-observable time, in seconds.
        def lead_time(cells)
          seconds = cells.map do |cell|
            Time.parse(cell.fetch("decision_at")).to_f -
              Time.parse(cell.fetch("first_observable_at")).to_f
          end
          mean(seconds)
        end

        # Missed-catastrophe cost: the gold intent is a catastrophe-averting
        # action (risk R2+) and no such intent was proposed. False-action cost:
        # an intent was proposed when the gold abstained. Reported separately
        # (never netted), scaled by the protocol's frozen costs.
        def action_utility(cells, missed_cost: 100.0, false_cost: 1.0)
          missed = cells.count do |cell|
            gold = cell["gold_risk_class"]
            !gold.nil? && risk_rank(gold) >= 2 &&
              !Array(cell.fetch("intent_risk_classes", [])).any? { |risk| risk_rank(risk) >= 2 }
          end
          false_actions = cells.count do |cell|
            cell["gold_risk_class"].nil? && !Array(cell.fetch("intent_risk_classes", [])).empty?
          end
          {
            "missed_catastrophes" => missed,
            "false_actions" => false_actions,
            "missed_catastrophe_cost" => missed * missed_cost,
            "false_action_cost" => false_actions * false_cost
          }
        end

        # Abstention quality (real-world sensor WP-T3): the supervisor should
        # abstain — propose no actionable (R1+) intent — EXACTLY when the oracle
        # marks the cell as one where action is not warranted (insufficient
        # evidence, already-corrected, ambient-driven, transient spike). Rewards a
        # correct act/abstain choice per cell; a score in [0,1]. A fixed-threshold
        # baseline that alarms on every high reading scores poorly on the conflict
        # cells; a supervisor that abstains there scores high.
        def abstention_quality(cells)
          return 0.0 if cells.empty?

          mean(cells.map { |cell| abstained?(cell) == abstain_expected?(cell) ? 1.0 : 0.0 })
        end

        # Counterfactual regret (WP-T3): utility lost vs the oracle-optimal
        # act/abstain choice, per cell. A MISSED action (abstained when action was
        # warranted) costs missed_cost; a FALSE action (acted when abstention was
        # warranted) costs false_cost. Reported as a mean; lower is better. The
        # costs are the SAME frozen asymmetry action_utility uses (a missed
        # catastrophe dwarfs a false alarm).
        def counterfactual_regret(cells, missed_cost: 100.0, false_cost: 1.0)
          return 0.0 if cells.empty?

          mean(cells.map do |cell|
            expected_abstain = abstain_expected?(cell)
            if abstained?(cell) && !expected_abstain
              missed_cost
            elsif !abstained?(cell) && expected_abstain
              false_cost
            else
              0.0
            end
          end)
        end

        # A cell abstained when it carries no actionable (R1+) intent — an empty
        # or purely-R0 (watch / evidence-request) intent set.
        def self.abstained?(cell)
          Array(cell.fetch("intent_risk_classes", [])).none? { |risk| risk_rank(risk) >= 1 }
        end

        def self.abstain_expected?(cell)
          cell["abstain_expected"] == true
        end

        def cost_per_cell(cells)
          {
            "provider_tokens" => cells.sum { |cell| cell.fetch("tokens", 0).to_i },
            "tool_bytes" => cells.sum { |cell| cell.fetch("tool_bytes", 0).to_i },
            "per_cell_mean" => cells.empty? ? 0.0 :
              cells.sum { |cell| cell.fetch("tokens", 0).to_i + cell.fetch("tool_bytes", 0).to_i } /
              cells.length.to_f
          }
        end

        def self.risk_rank(risk_class)
          {"R0" => 0, "R1" => 1, "R2" => 2, "R3" => 3}.fetch(risk_class.to_s.upcase, 3)
        end

        def self.mean(values)
          values.empty? ? 0.0 : values.sum / values.length.to_f
        end

        def self.confusion(cells, code)
          {
            "tp" => cells.count { |cell| cell.fetch("primary_code") == code && cell.fetch("truth_code") == code },
            "fp" => cells.count { |cell| cell.fetch("primary_code") == code && cell.fetch("truth_code") != code },
            "fn" => cells.count { |cell| cell.fetch("primary_code") != code && cell.fetch("truth_code") == code }
          }
        end

        def self.f1(confusion)
          precision = confusion["tp"] + confusion["fp"] == 0 ? 0.0 :
            confusion["tp"] / (confusion["tp"] + confusion["fp"]).to_f
          recall_value = confusion["tp"] + confusion["fn"] == 0 ? 0.0 :
            confusion["tp"] / (confusion["tp"] + confusion["fn"]).to_f
          return 0.0 if precision.zero? && recall_value.zero?

          2 * precision * recall_value / (precision + recall_value)
        end

        def self.recall(confusion)
          confusion["tp"] + confusion["fn"] == 0 ? 0.0 :
            confusion["tp"] / (confusion["tp"] + confusion["fn"]).to_f
        end

        def self.one_hot(code, codes)
          codes.to_h { |candidate| [candidate, candidate == code ? 1.0 : 0.0] }
        end

        def self.calibration_rows(cells, codes)
          cells.map do |cell|
            confidence = normalized(cell.fetch("probabilities"), codes)
                           .fetch(cell.fetch("primary_code"))
            correct = cell.fetch("primary_code") == cell.fetch("truth_code")
            [confidence, correct]
          end
        end

        # Completes a sparse probability mapping over the code set and
        # renormalizes, so a model that omitted a code still scores honestly.
        def self.normalized(probabilities, codes)
          completed = codes.to_h do |code|
            [code, probabilities.fetch(code, 0.0).to_f]
          end
          total = completed.values.sum
          return completed.transform_values { |value| 1.0 / codes.length } if total.zero?

          completed.transform_values { |value| value / total }
        end
      end
    end
  end
end
