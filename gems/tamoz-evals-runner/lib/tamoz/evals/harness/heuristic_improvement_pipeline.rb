# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # ADR-023 self-improvement, composed end to end (non-runtime, ADR-025):
      # generate one bounded heuristic from verified trajectories, evaluate it on
      # a DISTINCT holdout, decide pass/fail, and assemble the immutable
      # provenance — producing one vetted, promotion-ready bundle.
      #
      # It STOPS at the human gate. It returns the bundle a human approves and a
      # durable promoter records; it never mutates behavior itself. The pieces are
      # the production ones (`Improvement::Generator`, the paired evaluation whose
      # seal `Improvement::EvaluationReport` verifies, `Improvement::Provenance`),
      # so a promoter re-derives and re-checks exactly what this produced.
      class HeuristicImprovementPipeline
        # `candidate` is nil when the trajectories do not clear the evidence floor
        # — the honest empty outcome, not a weaker heuristic.
        Bundle = Data.define(:candidate, :report, :provenance, :decision) do
          def generated? = !candidate.nil?
          def passed? = generated? && decision.fetch("passed") == true
          # Promotion-ready: a candidate that passed and carries complete provenance.
          def promotable? = passed? && !provenance.nil? && provenance.complete?
        end

        def initialize(corpus:, generator_principal:, evaluator_principal:, promoter_principal:,
                       behavior_version_before:, behavior_version_after:,
                       rollback_snapshot_digest:, regression_tasks: [])
          if String(generator_principal) == String(evaluator_principal)
            raise ArgumentError, "the evaluator principal must differ from the generator principal"
          end

          @corpus = corpus
          @generator_principal = String(generator_principal)
          @evaluator_principal = String(evaluator_principal)
          @promoter_principal = String(promoter_principal)
          @behavior_version_before = String(behavior_version_before)
          @behavior_version_after = String(behavior_version_after)
          @rollback_snapshot_digest = String(rollback_snapshot_digest)
          @regression_tasks = regression_tasks
        end

        def run(recorded_at: 0)
          improvement = Tamoz::Agent::Improvement
          generator = build_generator(improvement)
          candidate = generator.generate(trajectory_paths: @corpus.train_trajectory_paths)
          return Bundle.new(candidate: nil, report: nil, provenance: nil, decision: nil) unless candidate

          report = evaluate(candidate)
          body = improvement::EvaluationReport.verify!(report)
          decision = improvement::EvaluationReport.decide(body)
          provenance = build_provenance(improvement, generator, candidate, body, recorded_at:)
          Bundle.new(candidate:, report:, provenance:, decision:)
        end

        private

        def build_generator(improvement)
          improvement::Generator.new(
            toolbox: Tamoz::Tools::Toolbox.new(root: @corpus.train_root),
            principal: @generator_principal,
            protected_paths: [@corpus.holdout_root, @corpus.evaluator_root]
          )
        end

        def evaluate(candidate)
          HeuristicPairedEvaluation.new(
            corpus: @corpus, evaluator_principal: @evaluator_principal,
            generator_principal: @generator_principal, regression_tasks: @regression_tasks
          ).evaluate(candidate)
        end

        def build_provenance(improvement, generator, candidate, body, recorded_at:)
          improvement::Provenance.new(
            candidate_id: candidate.heuristic_id,
            source_trajectories: generator.source_refs(trajectory_paths: @corpus.train_trajectory_paths),
            corpus_boundary: {
              "train_digest" => @corpus.train_digest, "holdout_digest" => @corpus.holdout_digest,
              "train_ids" => @corpus.train_ids, "holdout_ids" => @corpus.holdout_ids, "disjoint" => true
            },
            affected_behavior: {
              "surface" => "planning",
              "behavior_version_before" => @behavior_version_before,
              "behavior_version_after" => @behavior_version_after
            },
            policy_risk: {
              "gate_classes" => improvement::EvaluationReport::HEURISTIC_GATE_CLASSES,
              "risk_class" => "reversible_local_prompt_region", "reversible" => true, "grants_authority" => false
            },
            artifact_digests: {
              "candidate_digest" => candidate.digest,
              "snapshot_digest" => Tamoz::Agent::Memory::BehaviorTransition.snapshot_digest(candidate.snapshot),
              "generator_digest" => generator.digest
            },
            evaluation_lineage: {
              "report_digest" => improvement::EvaluationReport.seal(body),
              "evaluator_principal" => @evaluator_principal, "generator_principal" => @generator_principal,
              "development_score" => body.fetch("development").fetch("candidate").fetch("passed"),
              "holdout_score" => body.fetch("holdout").fetch("candidate").fetch("passed"),
              "paired_task_digest" => body.fetch("paired_task_digest")
            },
            rollback_target: {
              "behavior_version" => @behavior_version_before, "snapshot_digest" => @rollback_snapshot_digest
            },
            created_by: @promoter_principal, recorded_at:
          )
        end
      end
    end
  end
end
