# frozen_string_literal: true

module Tamoz
  module Agent
    module Improvement
      # P12-I3 (plan §7): "monitor the same gates promotion used".
      #
      # Literally the same gates: `Monitor` calls `EvaluationReport.verify!` and
      # `EvaluationReport.decide` — the identical functions `Promotion#promote`
      # calls — against a post-activation report produced by the same evaluator
      # principal over the same paired task set. A monitor with its own,
      # laxer notion of "still fine" would be exactly the drift invariant 28
      # exists to prevent.
      #
      # The monitor NEVER rolls back on its own. It returns a typed observation;
      # the rollback is a separate, human-gated, recorded transition. An
      # automatic rollback path would be an unreviewed behavior change.
      class Monitor
        Observation = Data.define(:healthy, :regression, :decision, :reasons) do
          def regression? = regression
          def healthy? = healthy

          def to_h
            {
              "healthy" => healthy,
              "regression" => regression,
              "decision" => decision,
              "reasons" => reasons
            }
          end
        end

        def initialize(promotion_report:)
          @baseline_body = EvaluationReport.verify!(promotion_report)
          @baseline_decision = EvaluationReport.decide(@baseline_body)
          @baseline_paired_task_digest = @baseline_body.fetch("paired_task_digest")
        end

        attr_reader :baseline_decision

        # Compare a post-activation report against the gates the promotion
        # cleared. A report that fails the seal is not "unhealthy" — it is a
        # tampering attempt and propagates (`EvaluatorTamperError`), because a
        # monitor that downgraded a broken seal to a metric would be the
        # concealment path the plan's hard-zero gate forbids.
        #
        # A post-activation report over a DIFFERENT paired task set is also not
        # an observation: margin deltas across different tasks are meaningless,
        # and accepting them would let a drifting candidate look healthy. The
        # same-task-set check is therefore a refusal, not a metric.
        def observe(report)
          body = EvaluationReport.verify!(report)
          if body.fetch("paired_task_digest") != @baseline_paired_task_digest
            raise EvaluatorTamperError,
                  "the observed report is over a different paired task set than " \
                  "the promotion report"
          end
          decision = EvaluationReport.decide(body)
          reasons = decision.fetch("reasons").dup
          if decision.fetch("holdout_margin") < @baseline_decision.fetch("holdout_margin")
            reasons << "holdout margin fell from #{@baseline_decision.fetch("holdout_margin")} " \
                       "to #{decision.fetch("holdout_margin")}"
          end
          if decision.fetch("development_margin") < @baseline_decision.fetch("development_margin")
            reasons << "development margin fell from " \
                       "#{@baseline_decision.fetch("development_margin")} " \
                       "to #{decision.fetch("development_margin")}"
          end
          Observation.new(
            healthy: reasons.empty?,
            regression: !reasons.empty?,
            decision:,
            reasons: reasons.freeze
          )
        end
      end
    end
  end
end
