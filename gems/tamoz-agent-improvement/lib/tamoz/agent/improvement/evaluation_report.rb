# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Improvement
      # P12-I2 (plan §7): the paired baseline/holdout evaluation report and the
      # gates that read it.
      #
      # The RUNNER lives in `tamoz-evals`
      # (`Harness::HeuristicPairedEvaluation`); the SEAL and every gate live
      # here, in production code, because the gates must hold at promotion time
      # in a process that has never loaded the harness. `tamoz-evals` calls
      # `seal` to produce a report; `tamoz-agent` calls `verify!` before any
      # transition is recorded. No production gem depends on `tamoz-evals`.
      #
      # Hard-zero gates (plan §1, §8) enforced here:
      #
      # * **evaluator tampering** — the seal covers the whole report body
      #   (arms, scores, task set, principals). Any edit, including flipping one
      #   holdout case from fail to pass, breaks the seal and raises
      #   `EvaluatorTamperError`. The seal is over CANONICAL bytes, so a
      #   reordering that changes nothing is not a false alarm and a reordering
      #   that changes an outcome is.
      # * **self-promotion** — the evaluator principal must differ from the
      #   generator principal, and neither may be the candidate itself.
      # * **blind pairing** — both arms must have run the IDENTICAL task set
      #   (one `paired_task_digest` shared by both arms); a candidate scored on
      #   an easier task set is not a paired evaluation.
      module EvaluationReport
        SEAL_DOMAIN = "tamoz.agent.improvement.evaluation_seal.v1\n"
        FORMAT_VERSION = 1

        # Plan §7 P12-I2, verbatim: "Human gates for: prompt hierarchy, tools,
        # roots, credentials, policy, evaluator, skills/scripts, code."
        # A candidate declaring ANY of these classes cannot activate without a
        # resolved human approval artifact.
        HUMAN_GATE_CLASSES = %w[
          prompt_hierarchy tools roots credentials policy evaluator
          skills_scripts code
        ].freeze

        # A promoted heuristic is injected into the planning prompt as a
        # delimited region, so it always touches the prompt hierarchy. The gate
        # is therefore never vacuous for this phase's candidate.
        HEURISTIC_GATE_CLASSES = %w[prompt_hierarchy].freeze

        HUMAN_GATE_PREFIX = "human:"

        REQUIRED_KEYS = %w[
          format_version candidate_digest generator_principal evaluator_principal
          paired_task_digest development holdout
        ].freeze
        ARM_KEYS = %w[baseline candidate].freeze
        SCORE_KEYS = %w[passed total task_digest].freeze

        module_function

        # Compute the seal over the canonical report body. Called by the
        # evaluator principal in `tamoz-evals`; recomputed by `verify!` here.
        def seal(body)
          Tamoz::Core.digest(SEAL_DOMAIN, body)
        end

        def sealed(body)
          canonical = Tamoz::Core.canonical(body)
          canonical.merge("seal" => seal(canonical))
        end

        # Verify a sealed report. Raises `EvaluatorTamperError` on ANY
        # structural break; returns the canonical body on success.
        def verify!(report)
          unless report.is_a?(Hash)
            raise EvaluatorTamperError, "evaluation report must be an object"
          end

          claimed = report["seal"]
          if String(claimed).empty?
            raise EvaluatorTamperError, "evaluation report carries no evaluator seal"
          end

          body = Tamoz::Core.canonical(report.reject { |key, _| key == "seal" })
          unless seal(body) == claimed
            raise EvaluatorTamperError,
                  "evaluation report seal does not match its content; the report was " \
                  "modified after the evaluator sealed it"
          end

          assert_shape!(body)
          assert_principals!(body)
          assert_paired!(body)
          body
        end

        # A sealed report must still be complete and in the supported format.
        def assert_shape!(body)
          REQUIRED_KEYS.each do |key|
            next unless body[key].nil? || (body[key].respond_to?(:empty?) && body[key].empty?)

            raise EvaluatorTamperError, "evaluation report is missing #{key}"
          end
          return if body.fetch("format_version") == FORMAT_VERSION

          raise EvaluatorTamperError, "unsupported evaluation report format_version"
        end

        # The evaluator, the generator, and the candidate are three distinct
        # identities. A report where any two coincide is a self-promotion
        # attempt (invariant 34, plan §1 hard-zero).
        def assert_principals!(body)
          evaluator = String(body.fetch("evaluator_principal"))
          generator = String(body.fetch("generator_principal"))
          if evaluator == generator
            raise SelfPromotionError,
                  "the evaluator principal (#{evaluator}) is the generator principal; " \
                  "a candidate cannot evaluate itself"
          end
          return unless evaluator == String(body.fetch("candidate_digest"))

          raise SelfPromotionError, "the evaluator principal is the candidate itself"
        end

        # Pairing has two halves and both are checked:
        #
        # * WITHIN a partition, the baseline and candidate arms must have run
        #   the IDENTICAL task set (same `task_digest`) — otherwise the
        #   comparison is between two different exams.
        # * ACROSS partitions, development and holdout must NOT be the same task
        #   set — otherwise the "holdout" is the training set wearing a label,
        #   and the holdout margin proves nothing.
        #
        # `paired_task_digest` binds both partition digests together, so the
        # seal covers which exams were sat.
        def assert_paired!(body)
          per_partition = %w[development holdout].to_h do |partition|
            arms = body.fetch(partition)
            unless arms.is_a?(Hash)
              raise EvaluatorTamperError, "evaluation report #{partition} is not an object"
            end

            digests = ARM_KEYS.map { |arm| assert_arm!(partition, arm, arms[arm]) }
            unless digests.uniq.length == 1
              raise EvaluatorTamperError,
                    "evaluation report #{partition} arms did not run the identical task set"
            end

            [partition, digests.first]
          end

          if per_partition.fetch("development") == per_partition.fetch("holdout")
            raise EvaluatorTamperError,
                  "the holdout partition ran the development task set; the holdout is not held out"
          end

          expected = paired_task_digest(
            per_partition.fetch("development"), per_partition.fetch("holdout")
          )
          return if String(body.fetch("paired_task_digest")) == expected

          raise EvaluatorTamperError,
                "evaluation report paired_task_digest does not bind the partition task sets"
        end

        # The binding digest over the two partition task sets. `tamoz-evals`
        # computes it with this same function, so there is one definition of
        # "these are the exams that were sat".
        def paired_task_digest(development_digest, holdout_digest)
          Tamoz::Core.digest(
            SEAL_DOMAIN, [String(development_digest), String(holdout_digest)]
          )
        end

        def assert_arm!(partition, arm, scores)
          unless scores.is_a?(Hash)
            raise EvaluatorTamperError, "evaluation report #{partition}/#{arm} is missing"
          end

          SCORE_KEYS.each do |key|
            next unless scores[key].nil?

            raise EvaluatorTamperError, "evaluation report #{partition}/#{arm} is missing #{key}"
          end
          unless scores.fetch("total").to_i.positive?
            raise EvaluatorTamperError, "evaluation report #{partition}/#{arm} ran no tasks"
          end
          if scores.fetch("passed").to_i > scores.fetch("total").to_i
            raise EvaluatorTamperError,
                  "evaluation report #{partition}/#{arm} passed more tasks than it ran"
          end
          String(scores.fetch("task_digest"))
        end

        # The promotion decision, derived only from a VERIFIED report. The
        # candidate must strictly improve on development AND must not regress on
        # the protected holdout. Returns a typed decision hash; it never
        # promotes anything itself.
        def decide(body)
          development = margin(body.fetch("development"))
          holdout = margin(body.fetch("holdout"))
          reasons = []
          reasons << "development margin #{development} is not an improvement" unless development.positive?
          reasons << "holdout margin #{holdout} is a regression" if holdout.negative?
          {
            "development_margin" => development,
            "holdout_margin" => holdout,
            "passed" => reasons.empty?,
            "reasons" => reasons
          }
        end

        def margin(arms)
          arms.fetch("candidate").fetch("passed").to_i - arms.fetch("baseline").fetch("passed").to_i
        end

        # Plan §7 P12-I2 human gate. `gate_classes` is what the candidate
        # declares it touches; an unknown class is refused rather than ignored,
        # so a typo cannot silently drop a gate.
        def assert_human_gate!(gate_classes:, evidence:)
          classes = Array(gate_classes).map(&:to_s)
          unknown = classes - HUMAN_GATE_CLASSES
          unless unknown.empty?
            raise ImprovementPolicyError, "unknown human-gate classes #{unknown.sort.inspect}"
          end
          return true if classes.empty?

          text = String(evidence)
          unless text.start_with?(HUMAN_GATE_PREFIX) && text.length > HUMAN_GATE_PREFIX.length
            raise UngatedActivationError,
                  "activation touching #{classes.sort.join(", ")} requires a resolved human " \
                  "approval artifact (#{HUMAN_GATE_PREFIX}<actor>); got #{text.inspect}"
          end
          true
        end
      end
    end
  end
end
