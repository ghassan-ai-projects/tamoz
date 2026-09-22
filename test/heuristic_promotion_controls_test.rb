# frozen_string_literal: true

require_relative 'test_helper'

# The discrimination gate for the self-improvement promotion pipeline
# (GAPS-20260918 G3). ADR-023's claim is that a heuristic is promoted only on a
# distinct holdout, behind a human gate, by a third party, with rollback
# measured. The pipeline is built and its happy path is tested
# (heuristic_improvement_pipeline_test); this proves the gate REJECTS the
# adversaries it exists to stop — an overfit candidate, a forged report, a
# self-promoter, an ungated activation — and that a rollback restores the prior
# epoch byte-identically. Same discipline as the comms/mission/thermal controls:
# an oracle passes, each adversary is blocked by the specific gate it targets.
class HeuristicPromotionControlsTest < Minitest::Test
  Harness = Tamoz::Evals::Harness
  Improvement = Tamoz::Agent::Improvement
  EvaluationReport = Improvement::EvaluationReport

  # ---- decide(): the holdout gate, ADR-023's core (pure over a report body) --

  def report_body(dev_candidate:, dev_baseline:, holdout_candidate:, holdout_baseline:)
    {
      'development' => { 'candidate' => { 'passed' => dev_candidate }, 'baseline' => { 'passed' => dev_baseline } },
      'holdout' => { 'candidate' => { 'passed' => holdout_candidate }, 'baseline' => { 'passed' => holdout_baseline } }
    }
  end

  def test_oracle_candidate_clears_the_holdout_gate
    decision = EvaluationReport.decide(
      report_body(dev_candidate: 6, dev_baseline: 3, holdout_candidate: 5, holdout_baseline: 3)
    )
    assert decision.fetch('passed'), decision.fetch('reasons').inspect
  end

  # The adversary the holdout exists to catch: it gamed the development set and
  # regresses on the held-out set.
  def test_overfit_candidate_is_refused_on_holdout_regression
    decision = EvaluationReport.decide(
      report_body(dev_candidate: 8, dev_baseline: 3, holdout_candidate: 2, holdout_baseline: 4)
    )
    refute decision.fetch('passed')
    assert(decision.fetch('reasons').any? { |reason| reason.include?('holdout margin') })
  end

  # null: no development improvement at all.
  def test_candidate_with_no_development_improvement_is_refused
    decision = EvaluationReport.decide(
      report_body(dev_candidate: 3, dev_baseline: 3, holdout_candidate: 5, holdout_baseline: 3)
    )
    refute decision.fetch('passed')
    assert(decision.fetch('reasons').any? { |reason| reason.include?('development margin') })
  end

  # FINDING (recorded, not a failure): the gate's holdout bar is "no regression",
  # not "holdout improvement". A candidate that improves development but is
  # exactly neutral on the holdout still promotes. Whether that is strict enough
  # for ADR-023 is a policy question; this pins the current behaviour so a change
  # to it is deliberate. See GAPS-20260918 G3.
  def test_recorded_neutral_holdout_still_promotes
    decision = EvaluationReport.decide(
      report_body(dev_candidate: 6, dev_baseline: 3, holdout_candidate: 4, holdout_baseline: 4)
    )
    assert decision.fetch('passed'),
           'a neutral holdout currently passes — the bar is no-regression, not improvement'
    assert_equal 0, decision.fetch('holdout_margin')
  end

  # ---- the promotion gate, through the real Promotion + Memory::Engine --------

  def with_promotion
    Harness::HeuristicCorpus.create(inputs: RunnerInputs.heuristic) do |corpus|
      with_engine do |engine|
        seed_baseline(engine)
        pipeline = Harness::HeuristicImprovementPipeline.new(
          corpus:, generator_principal: 'principal.generator', evaluator_principal: 'principal.evaluator',
          promoter_principal: 'principal.operator',
          behavior_version_before: 'tamoz.agent.session/2', behavior_version_after: 'tamoz.agent.session/3',
          rollback_snapshot_digest: "sha256:#{'a' * 64}", regression_tasks: RunnerInputs.regression_tasks
        )
        bundle = pipeline.run
        assert bundle.promotable?, 'the oracle bundle must be promotable before we perturb it'
        body = EvaluationReport.verify!(bundle.report)
        resolver = ->(seal) { seal == EvaluationReport.seal(body) ? bundle.report : nil }
        yield engine, bundle, resolver
      end
    end
  end

  def promote(engine, bundle, resolver, actor: 'principal.operator', human_gate_evidence: 'human:operator-1')
    Improvement::Promotion.new(engine).promote(
      candidate: bundle.candidate, provenance: bundle.provenance, report: bundle.report,
      human_gate_evidence:, actor:, evidence_resolver: resolver
    )
  end

  def test_oracle_bundle_promotes
    with_promotion do |engine, bundle, resolver|
      result = promote(engine, bundle, resolver)
      transition_id = result.fetch('transition').transition_id
      engine.transitions.claim(transition_id:, owner: 'intake', attempt: 1)
      engine.transitions.finalize(transition_id:, consumed_by: 'session.canary')
      assert_equal 'tamoz.agent.session/3', engine.transitions.active.fetch('active_version')
    end
  end

  # A candidate cannot supply its own evaluation evidence: the report must
  # resolve to the artifact the evaluator stored in its protected partition.
  def test_forged_report_is_refused
    with_promotion do |engine, bundle, _resolver|
      assert_raises(Improvement::EvaluatorTamperError) do
        promote(engine, bundle, ->(_seal) { nil })
      end
    end
  end

  # The promoting actor must be a third party, not the generator of the candidate.
  def test_self_promotion_by_the_generator_is_refused
    with_promotion do |engine, bundle, resolver|
      assert_raises(Improvement::SelfPromotionError) do
        promote(engine, bundle, resolver, actor: 'principal.generator')
      end
    end
  end

  # Activation touching a gated class needs a resolved human approval artifact.
  def test_missing_human_gate_is_refused
    with_promotion do |engine, bundle, resolver|
      assert_raises(Improvement::UngatedActivationError) do
        promote(engine, bundle, resolver, human_gate_evidence: 'operator-said-ok')
      end
    end
  end

  # Rollback returns the served injection region to the prior epoch byte-for-byte.
  def test_rollback_restores_the_prior_epoch_byte_identically
    with_promotion do |engine, bundle, resolver|
      result = promote(engine, bundle, resolver)
      transition_id = result.fetch('transition').transition_id
      engine.transitions.claim(transition_id:, owner: 'intake', attempt: 1)
      engine.transitions.finalize(transition_id:, consumed_by: 'session.canary')

      promotion = Improvement::Promotion.new(engine)
      rollback = promotion.rollback(
        reason: 'canary regressed', actor: 'principal.operator', human_gate_evidence: 'human:operator-1'
      )
      target = rollback.fetch('transition')
      engine.transitions.claim(transition_id: target.transition_id, owner: 'intake', attempt: 1)
      engine.transitions.finalize(transition_id: target.transition_id, consumed_by: 'session.canary')

      proof = promotion.assert_rolled_back_byte_identical!(
        expected_snapshot_digest: rollback.fetch('target_snapshot_digest'),
        expected_injection_digest: rollback.fetch('injection_digest')
      )
      assert proof.fetch('byte_identical')
    end
  end

  private

  def with_engine
    Dir.mktmpdir('tamoz-promote-controls') do |dir|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, 'engine.sqlite3'))
      yield Tamoz::Agent::Memory::Engine.new(tenant: 'promotion-controls', adapter:)
    ensure
      adapter&.close
    end
  end

  def seed_baseline(engine)
    transition, = engine.transitions.record(
      kind: :wisdom_promotion, candidate_id: 'wis.default', candidate_digest: "sha256:#{'9' * 64}",
      behavior_snapshot: { 'wisdom' => 'default baseline' }, behavior_version_after: 'tamoz.agent.session/2',
      promotion_evidence_digest: "sha256:#{'7' * 64}", human_gate_evidence: 'human:operator-1',
      created_by: 'tamoz.agent.memory.wisdom'
    )
    engine.transitions.claim(transition_id: transition.transition_id, owner: 'intake', attempt: 1)
    engine.transitions.finalize(transition_id: transition.transition_id, consumed_by: 'session.seed')
  end
end
