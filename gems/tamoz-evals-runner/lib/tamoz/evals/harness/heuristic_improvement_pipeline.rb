# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # Composes the production pieces end to end (non-runtime, ADR-025): generate
      # -> distinct-holdout evaluation -> pass/fail decision -> immutable provenance,
      # producing one promotion-ready bundle. Stops at the human gate; never mutates.
      class HeuristicImprovementPipeline
        Bundle = Data.define(:candidate, :report, :provenance, :decision) do
          def generated? = !candidate.nil?
          def passed? = generated? && decision.fetch('passed') == true
          def promotable? = passed? && !provenance.nil? && provenance.complete?

          # The on-disk hand-off `tamoz improve promote` reads back.
          def to_h
            {
              'candidate' => candidate&.to_h, 'report' => report,
              'provenance' => provenance&.to_h, 'decision' => decision
            }
          end
        end

        # Who generates, who evaluates, and who records the promotion; the evaluator is never the generator.
        Principals = Data.define(:generator, :evaluator, :promoter) do
          def initialize(generator:, evaluator:, promoter:)
            if String(generator) == String(evaluator)
              raise ArgumentError, 'the evaluator principal must differ from the generator principal'
            end

            super(generator: String(generator), evaluator: String(evaluator), promoter: String(promoter))
          end
        end

        # The behavior version the candidate replaces, the one it becomes, and the snapshot a rollback restores.
        BehaviorChange = Data.define(:before, :after, :rollback_snapshot_digest) do
          def initialize(before:, after:, rollback_snapshot_digest:)
            super(before: String(before), after: String(after),
                  rollback_snapshot_digest: String(rollback_snapshot_digest))
          end
        end

        def initialize(corpus:, principals:, change:, regression_tasks: [])
          @corpus = corpus
          @generator_principal = principals.generator
          @evaluator_principal = principals.evaluator
          @promoter_principal = principals.promoter
          @behavior_version_before = change.before
          @behavior_version_after = change.after
          @rollback_snapshot_digest = change.rollback_snapshot_digest
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
            corpus_boundary:, affected_behavior:, policy_risk: policy_risk(improvement),
            artifact_digests: artifact_digests(generator, candidate),
            evaluation_lineage: evaluation_lineage(improvement, body),
            rollback_target:, created_by: @promoter_principal, recorded_at:
          )
        end

        def corpus_boundary
          {
            'train_digest' => @corpus.train_digest, 'holdout_digest' => @corpus.holdout_digest,
            'train_ids' => @corpus.train_ids, 'holdout_ids' => @corpus.holdout_ids, 'disjoint' => true
          }
        end

        def affected_behavior
          {
            'surface' => 'planning',
            'behavior_version_before' => @behavior_version_before,
            'behavior_version_after' => @behavior_version_after
          }
        end

        def policy_risk(improvement)
          {
            'gate_classes' => improvement::EvaluationReport::HEURISTIC_GATE_CLASSES,
            'risk_class' => 'reversible_local_prompt_region', 'reversible' => true, 'grants_authority' => false
          }
        end

        def artifact_digests(generator, candidate)
          {
            'candidate_digest' => candidate.digest,
            'snapshot_digest' => Tamoz::Agent::Memory::BehaviorTransition.snapshot_digest(candidate.snapshot),
            'generator_digest' => generator.digest
          }
        end

        def evaluation_lineage(improvement, body)
          {
            'report_digest' => improvement::EvaluationReport.seal(body),
            'evaluator_principal' => @evaluator_principal, 'generator_principal' => @generator_principal,
            'development_score' => body.fetch('development').fetch('candidate').fetch('passed'),
            'holdout_score' => body.fetch('holdout').fetch('candidate').fetch('passed'),
            'paired_task_digest' => body.fetch('paired_task_digest')
          }
        end

        def rollback_target
          { 'behavior_version' => @behavior_version_before, 'snapshot_digest' => @rollback_snapshot_digest }
        end
      end
    end
  end
end
