# frozen_string_literal: true

require "digest"
require "time"

module Tamoz
  module Evals
    module Benchmark
      # P7: assembles the frozen report from scored cells. Pure — the same
      # cells re-scored anywhere produce the same numbers, and the protocol
      # digest is bound so a report can never claim a protocol it was not run
      # against. The verdict is derived from the go rule's FULL conjunction:
      # a 95% paired interval clearing the frozen minimum practical effect
      # AND zero stop-rule violations AND the control gate passed AND no
      # pilot (fixture) cells. Anything less is negative or inconclusive,
      # plainly.
      class Report
        def self.build(protocol:, cells:, model_identity:, protocol_sha256:,
                       label: "", controls_passed: false, go_baseline_cells: nil)
          new(protocol:, cells:, model_identity:, protocol_sha256:,
              label:, controls_passed:, go_baseline_cells:).build
        end

        def initialize(protocol:, cells:, model_identity:, protocol_sha256:,
                       label: "", controls_passed: false, go_baseline_cells: nil)
          @protocol = protocol
          @cells = cells
          @model_identity = model_identity
          @protocol_sha256 = protocol_sha256
          @label = label
          @controls_passed = controls_passed
          @go_baseline_cells = go_baseline_cells
          @produced = cells.reject { |cell| cell.fetch("status", "produced") == "failed" }
          @codes = codes_from(cells)
        end

        def build
          metrics = compute_metrics
          baselines = run_baselines
          strongest = strongest_baseline(baselines)
          comparison = Comparison.new.paired(
            candidate: @produced,
            baseline: strongest.fetch("cells"),
            cells: @produced,
            metric: method(:per_cell_correctness),
            minimum_effect: @protocol.dig("thresholds", "minimum_practical_effect"),
            confidence: @protocol.dig("thresholds", "confidence_interval"),
            seed: @protocol.dig("statistics", "bootstrap_seed")
          )
          violations = stop_rule_violations
          {
            "benchmark_protocol_version" => @protocol.fetch("benchmark_protocol_version"),
            "protocol_sha256" => @protocol_sha256,
            "model_identity" => @model_identity,
            "label" => @label,
            "cell_count" => @cells.length,
            "failed_cell_count" => @cells.length - @produced.length,
            "metrics" => metrics,
            "baselines" => baseline_summary(baselines),
            "strongest_baseline" => strongest.fetch("name"),
            "comparison" => comparison,
            "stop_rule_violations" => violations,
            "controls_passed" => @controls_passed,
            "verdict" => verdict(comparison, violations),
            "content_digest" => content_digest(metrics, baselines, comparison, violations)
          }
        end

        private

        def codes_from(cells)
          cells.flat_map { |cell| cell.fetch("probabilities", {}).keys }
               .concat(cells.map { |cell| cell.fetch("truth_code") })
               .concat(cells.map { |cell| cell.fetch("primary_code", nil) }.compact)
               .uniq.sort
        end

        def compute_metrics
          {
            "diagnosis" => {
              "macro_f1" => Metrics.macro_f1(@produced, @codes),
              "balanced_accuracy" => Metrics.balanced_accuracy(@produced, @codes)
            },
            "probability" => {
              "brier" => Metrics.brier(@produced, @codes),
              "log_loss" => Metrics.log_loss(@produced, @codes),
              "calibration" => Metrics.calibration(@produced, @codes),
              "risk_coverage" => Metrics.risk_coverage(@produced, @codes)
            },
            "evidence" => {
              "fabricated_reference_rate" => Metrics.fabricated_reference_rate(@produced)
            },
            "timing" => {"lead_time" => Metrics.lead_time(@produced)},
            "utility" => Metrics.action_utility(
              @produced,
              missed_cost: @protocol.dig("scoring", "utility", "missed_catastrophe_cost"),
              false_cost: @protocol.dig("scoring", "utility", "false_action_cost")
            ),
            "cost" => Metrics.cost_per_cell(@produced)
          }
        end

        # Runs the preregistered baselines over the PRODUCED cells. Detector
        # baselines need each scenario family's metric/alarm pair from the
        # protocol freeze, or half the corpus (the climate family) is scored
        # against a metric it does not carry.
        def run_baselines
          names = @protocol.fetch("baselines")
          names.map do |name|
            cells = if name == "go_native_executor"
                      @go_baseline_cells
                    else
                      run_baseline(name)
                    end
            next nil if cells.nil?

            {"name" => name, "cells" => cells, "macro_f1" => Metrics.macro_f1(cells, @codes)}
          end.compact
        end

        def run_baseline(name)
          families = @protocol.dig("case_matrix", "scenario_families")
          # Convention: a strategy's keyword params are filled by name from
          # the family row (metric/alarm_code/threshold/operator) or the
          # statistics block (seed) — the protocol keys must match the
          # strategy signature, and a new strategy param needs a protocol
          # field before it can be fed.
          accepted = Baselines.method(name).parameters.filter_map do |kind, key|
            key if kind == :key || kind == :keyreq
          end
          @produced.group_by { |cell| cell.fetch("scenario_family") }.flat_map do |family_id, cells|
            family = families.find { |entry| entry.fetch("id") == family_id }
            kwargs = {}
            if family
              kwargs[:metric] = family["metric"] if accepted.include?(:metric)
              kwargs[:alarm_code] = family["alarm_code"] if accepted.include?(:alarm_code)
              kwargs[:threshold] = family["threshold"] if accepted.include?(:threshold)
              kwargs[:operator] = family["operator"] if accepted.include?(:operator)
            end
            kwargs[:seed] = @protocol.dig("statistics", "random_label_seed") if accepted.include?(:seed)
            Baselines.public_send(name, cells, @codes, **kwargs)
          end
        end

        def baseline_summary(baselines)
          baselines.map { |row| {"name" => row.fetch("name"), "macro_f1" => row.fetch("macro_f1")} }
        end

        def strongest_baseline(baselines)
          baselines.max_by { |row| row.fetch("macro_f1") }
        end

        # The paired per-cell quantity the go rule's interval is over: 1 when
        # the diagnosis is correct, 0 otherwise. (Macro-F1 is the corpus-level
        # metric; the interval needs a per-cell decomposition.)
        def per_cell_correctness(cell)
          cell.fetch("primary_code") == cell.fetch("truth_code") ? 1.0 : 0.0
        end

        # The frozen stop rules a report can detect from the scored cells: a
        # fabricated evidence reference, a decision before the first-observable
        # time (premature = leak), and a failed attempt that was not replaced
        # (intention-to-treat visibility). The harness enforces the rest
        # (fixture stop, cross-cell isolation) at run time.
        def stop_rule_violations
          violations = []
          fabricated = @produced.sum do |cell|
            (Array(cell.fetch("evidence_refs", [])) - Array(cell.fetch("valid_evidence_ids", []))).length
          end
          violations << "fabricated_evidence_reference" if fabricated.positive?
          premature = @produced.count do |cell|
            Time.parse(cell.fetch("decision_at")).to_f <
              Time.parse(cell.fetch("first_observable_at")).to_f
          end
          violations << "premature_decision" if premature.positive?
          violations << "unreported_attempt" if @cells.length != @produced.length
          violations
        end

        def verdict(comparison, violations)
          return "inconclusive" if @cells.empty? || @produced.empty?
          return "inconclusive" unless violations.empty?
          # The go rule's claim requires the preregistered controls to have
          # passed AND a real-provider run: a pilot (fixture) cell or an
          # unpassed control gate can never produce a go — the label and the
          # gate are the honest guards.
          return "inconclusive" if @cells.any? { |cell| cell.fetch("label", "") == "pilot" }
          return "inconclusive" unless @controls_passed

          if comparison.fetch("meets_minimum_effect")
            "go"
          elsif comparison.fetch("mean_difference") <= 0
            "negative"
          else
            "inconclusive"
          end
        end

        def content_digest(metrics, baselines, comparison, violations)
          "sha256:#{Digest::SHA256.hexdigest(
            JSON.generate({"label" => @label, "metrics" => metrics, "baselines" => baselines,
                           "comparison" => comparison, "violations" => violations,
                           "controls_passed" => @controls_passed})
          )}"
        end
      end
    end
  end
end
