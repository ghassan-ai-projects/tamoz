# frozen_string_literal: true

require_relative "test_helper"

# The end-to-end self-improvement pipeline: generate -> holdout-evaluate ->
# decide -> provenance, producing one vetted, promotion-ready bundle. It stops
# at the human gate (it never promotes).
class HeuristicImprovementPipelineTest < Minitest::Test
  Harness = Tamoz::Evals::Harness
  Improvement = Tamoz::Agent::Improvement

  def with_pipeline(generator: "principal.generator", evaluator: "principal.evaluator")
    Harness::HeuristicCorpus.create(inputs: RunnerInputs.heuristic) do |corpus|
      yield Harness::HeuristicImprovementPipeline.new(
        corpus:, generator_principal: generator, evaluator_principal: evaluator,
        promoter_principal: "principal.operator",
        behavior_version_before: "tamoz.agent.session/1",
        behavior_version_after: "tamoz.agent.session/2",
        rollback_snapshot_digest: "sha256:#{"a" * 64}",
        regression_tasks: RunnerInputs.regression_tasks
      )
    end
  end

  def test_produces_a_promotion_ready_bundle
    with_pipeline do |pipeline|
      bundle = pipeline.run

      assert bundle.generated?, "the corpus should yield a candidate"
      assert bundle.passed?, "the candidate should pass its paired holdout evaluation"
      assert bundle.promotable?, "a passed candidate with complete provenance is promotion-ready"
      assert bundle.provenance.complete?
      assert bundle.decision.fetch("holdout_margin") >= 0
      # The report is the sealed artifact production verifies — re-verify it here.
      assert Improvement::EvaluationReport.verify!(bundle.report)
    end
  end

  def test_provenance_binds_the_candidate_and_the_report
    with_pipeline do |pipeline|
      bundle = pipeline.run
      lineage = bundle.provenance.evaluation_lineage
      assert_equal "principal.evaluator", lineage.fetch("evaluator_principal")
      assert_equal "principal.generator", lineage.fetch("generator_principal")
      assert_equal bundle.candidate.digest,
                   bundle.provenance.artifact_digests.fetch("candidate_digest")
    end
  end

  def test_evaluator_must_differ_from_generator
    error = assert_raises(ArgumentError) do
      with_pipeline(generator: "same", evaluator: "same") { |pipeline| pipeline.run }
    end
    assert_match(/evaluator principal must differ/, error.message)
  end

  # The whole loop, closed: raw trajectories -> generated + evaluated bundle ->
  # durable human-gated promotion -> activation -> the heuristic is live. Uses the
  # real Memory::Engine and Improvement::Promotion, not doubles.
  def test_bundle_promotes_into_live_behavior_end_to_end
    Harness::HeuristicCorpus.create(inputs: RunnerInputs.heuristic) do |corpus|
      with_engine do |engine|
        seed_baseline(engine)

        pipeline = Harness::HeuristicImprovementPipeline.new(
          corpus:, generator_principal: "principal.generator", evaluator_principal: "principal.evaluator",
          promoter_principal: "principal.operator",
          behavior_version_before: "tamoz.agent.session/2", behavior_version_after: "tamoz.agent.session/3",
          rollback_snapshot_digest: "sha256:#{"a" * 64}", regression_tasks: RunnerInputs.regression_tasks
        )
        bundle = pipeline.run
        assert bundle.promotable?

        body = Improvement::EvaluationReport.verify!(bundle.report)
        resolver = ->(seal) { seal == Improvement::EvaluationReport.seal(body) ? bundle.report : nil }
        result = Improvement::Promotion.new(engine).promote(
          candidate: bundle.candidate, provenance: bundle.provenance, report: bundle.report,
          human_gate_evidence: "human:operator-1", actor: "principal.operator", evidence_resolver: resolver
        )

        transition_id = result.fetch("transition").transition_id
        engine.transitions.claim(transition_id:, owner: "intake", attempt: 1)
        engine.transitions.finalize(transition_id:, consumed_by: "session.canary")

        assert_equal "tamoz.agent.session/3", engine.transitions.active.fetch("active_version")
      end
    end
  end

  private

  def with_engine
    Dir.mktmpdir("tamoz-improve-engine") do |dir|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, "engine.sqlite3"))
      yield Tamoz::Agent::Memory::Engine.new(tenant: "pipeline", adapter:)
    ensure
      adapter&.close
    end
  end

  def seed_baseline(engine)
    transition, = engine.transitions.record(
      kind: :wisdom_promotion, candidate_id: "wis.default", candidate_digest: "sha256:#{"9" * 64}",
      behavior_snapshot: {"wisdom" => "default baseline"}, behavior_version_after: "tamoz.agent.session/2",
      promotion_evidence_digest: "sha256:#{"7" * 64}", human_gate_evidence: "human:operator-1",
      created_by: "tamoz.agent.memory.wisdom"
    )
    engine.transitions.claim(transition_id: transition.transition_id, owner: "intake", attempt: 1)
    engine.transitions.finalize(transition_id: transition.transition_id, consumed_by: "session.seed")
  end
end
