# frozen_string_literal: true

require "digest"

module Tamoz
  module Evals
    module Harness
      # P12-I2 (plan §7): the paired baseline/holdout evaluation.
      #
      # This is a SCENARIO EXTENSION of the existing harness, not a second
      # harness: it reuses `CanonicalJSON`, `DeepFreeze`, and the corpus/holdout
      # posture that `MemoryHoldout`/`MemoryCell` established for P11-W, and it
      # produces an artifact that production code (`Improvement::EvaluationReport`)
      # verifies. It runs no subprocess and calls no model — the whole
      # evaluation is deterministic, which is what lets the same report be
      # re-derived and compared at monitor time.
      #
      # Two arms, two partitions, one exam per partition:
      #
      #   development/baseline   the raw task plan
      #   development/candidate  `heuristic.apply(raw task plan)`
      #   holdout/baseline       the raw HELD-OUT task plan
      #   holdout/candidate      `heuristic.apply(raw held-out task plan)`
      #
      # The evaluator is a DISTINCT principal from the generator and it holds
      # the oracle. The candidate is never handed the oracle, the holdout tasks,
      # or the report: `evaluate` takes only the heuristic value object.
      class HeuristicPairedEvaluation
        ORACLES = %w[read_before_patch bounded_plan].freeze

        attr_reader :evaluator_principal

        def initialize(corpus:, evaluator_principal:, generator_principal:)
          if String(evaluator_principal) == String(generator_principal)
            raise ExecutionError,
                  "the evaluator principal must differ from the generator principal"
          end

          @corpus = corpus
          @evaluator_principal = String(evaluator_principal)
          @generator_principal = String(generator_principal)
        end

        # Run both arms on both partitions and return the SEALED report. The
        # seal is computed by the production sealing function, so the artifact
        # this harness writes is the artifact production verifies — there is no
        # second definition of "sealed".
        #
        # `regression:` injects a P12-I3 regression: the held-out exam is
        # replaced by one the heuristic actively harms (a task whose plan
        # already reads the target through a DIFFERENT tool, so the inserted
        # precursor is redundant work the oracle counts against it).
        def evaluate(heuristic, regression: false)
          development = score_partition(@corpus.development_tasks, heuristic)
          holdout_tasks = regression ? regression_tasks : @corpus.holdout_tasks

          report = report_module.sealed(
            report_body(heuristic, development, score_partition(holdout_tasks, heuristic))
          )
          @corpus.write_evaluator_output(
            "report.#{regression ? "regression" : "promotion"}.json", report
          )
          DeepFreeze.call(report)
        end

        # The evaluator's own view of a single arm — exposed so a test can show
        # the arms really did run the identical task list.
        def task_digest(tasks)
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(tasks))}"
        end

        private

        # Loaded lazily and by name: `tamoz-evals` must never load
        # `tamoz-agent` at require time (the dependency-isolation test).
        def report_module
          Tamoz::Agent::Improvement::EvaluationReport
        end

        def report_body(heuristic, development, holdout)
          {
            "format_version" => report_module::FORMAT_VERSION,
            "candidate_digest" => heuristic.digest,
            "candidate_id" => heuristic.heuristic_id,
            "generator_principal" => @generator_principal,
            "evaluator_principal" => @evaluator_principal,
            "paired_task_digest" => report_module.paired_task_digest(
              development.fetch("task_digest"), holdout.fetch("task_digest")
            ),
            "development" => development.fetch("arms"),
            "holdout" => holdout.fetch("arms")
          }
        end

        def score_partition(tasks, heuristic)
          digest = task_digest(tasks)
          {
            "task_digest" => digest,
            "arms" => {
              "baseline" => arm(tasks, digest) { |steps| steps },
              "candidate" => arm(tasks, digest) { |steps| heuristic.apply(steps) }
            }
          }
        end

        def arm(tasks, digest)
          outcomes = tasks.map do |task|
            steps = yield(task.fetch("steps"))
            [task.fetch("task_id"), satisfies?(task, steps)]
          end
          {
            "passed" => outcomes.count { |_, ok| ok },
            "total" => outcomes.length,
            "task_digest" => digest,
            "outcomes" => outcomes.to_h
          }
        end

        # The oracles. Deterministic and model-independent — no model call, no
        # subprocess, no wall clock — so the same exam re-run at monitor time
        # yields the same numbers and a change in the numbers means a change in
        # the behavior, never in the weather.
        #
        # `read_before_patch` every `apply_patch` on a path is preceded by a
        #                     `read_file` on that same path.
        # `bounded_plan`      the plan fits the task's step budget. This is the
        #                     dimension along which "always read before you
        #                     patch" can be WORSE than the baseline: the extra
        #                     read costs a step.
        def satisfies?(task, steps)
          invariant = String(task.fetch("invariant"))
          unless ORACLES.include?(invariant)
            raise ExecutionError, "unknown oracle #{invariant.inspect}"
          end

          case invariant
          when "read_before_patch" then read_before_patch?(steps)
          when "bounded_plan" then steps.length <= task.fetch("step_budget").to_i
          end
        end

        def read_before_patch?(steps)
          read = []
          steps.each do |step|
            next unless step.is_a?(Hash)

            path = step.dig("arguments", "path")
            case String(step["tool"])
            when "read_file" then read << path
            when "apply_patch" then return false unless read.include?(path)
            end
          end
          true
        end

        # P12-I3 regression injection. The held-out distribution shifts to
        # budget-constrained tasks: the promoted heuristic still does what it
        # was promoted to do, but on a one-step budget the precursor it inserts
        # overflows the plan. Two of three held-out tasks now fail for the
        # candidate that the baseline passes, so the holdout margin goes
        # NEGATIVE and the very gate that admitted the heuristic rejects it.
        #
        # This is not a contrived misfire: adding a step is the heuristic's
        # actual cost, and a tighter budget is the environment change that makes
        # that cost decisive.
        def regression_tasks
          [
            {
              "task_id" => "r.tight-budget-one", "invariant" => "bounded_plan",
              "step_budget" => 1,
              "steps" => [patch_step("s1", "lib/reg-one.rb")]
            },
            {
              "task_id" => "r.tight-budget-two", "invariant" => "bounded_plan",
              "step_budget" => 1,
              "steps" => [patch_step("s1", "lib/reg-two.rb")]
            },
            {
              "task_id" => "r.blind-patch", "invariant" => "read_before_patch",
              "step_budget" => 8,
              "steps" => [patch_step("s1", "lib/reg-three.rb")]
            }
          ].freeze
        end

        def patch_step(id, path)
          {
            "id" => id, "tool" => "apply_patch", "purpose" => "patch the target",
            "arguments" => {"path" => path}, "verification" => "the check passes"
          }
        end
      end
    end
  end
end
