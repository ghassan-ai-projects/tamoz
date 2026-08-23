# frozen_string_literal: true

module Tamoz
  module Agent
    # P12-I (plan §7): the BEHAVIOR IMPROVEMENT half of bounded self-healing —
    # candidate provenance, one bounded heuristic generated from verified
    # trajectories, paired baseline/holdout evaluation, human gates, and
    # activation/rollback through the P11-W-owned `BehaviorTransition` seam.
    #
    # This namespace deliberately owns NO activation mechanism. Every behavior
    # change lands through `Memory::TransitionRegistry` with
    # `kind: :heuristic_promotion`; there is exactly one transition engine in
    # the tree and it belongs to P11-W (DR-1 revision 4).
    module Improvement
      # P12 plan §11 failure model. Repairable inputs are typed VALUES; policy
      # violations and integrity breaks PROPAGATE (invariant 17, D-7 merge).
      class ImprovementError < Error; end

      # Terminal policy violation: a candidate, generator, or promotion that
      # would exceed the phase's bounded scope.
      class ImprovementPolicyError < ImprovementError; end

      # Terminal (P12-ID): a provenance record missing a required field. The
      # message names the exact missing field so the gap is never guessed at.
      class ProvenanceIncompleteError < ImprovementError; end

      # Terminal (P12-I1, plan §7 C7/P3): the generator's capability grant
      # overlaps the protected holdout corpus or the evaluator's output. The
      # ENFORCEMENT is the toolbox root (an attempted read raises
      # `Tamoz::Tools::ToolPolicyError` at the capability boundary); this class
      # is the construction-time refusal to even build such a generator.
      class HoldoutIsolationError < ImprovementError; end

      # Terminal HARD-ZERO gate (plan §1, §8): the evaluation report's seal does
      # not match its content, its evaluator principal is not distinct from the
      # generator, or its task set is not the identical paired set.
      class EvaluatorTamperError < ImprovementError; end

      # Terminal HARD-ZERO gate (plan §1, invariant 34): a candidate attempting
      # to act as its own promoter, evaluator, or human gate.
      class SelfPromotionError < ImprovementError; end

      # Terminal (plan §7 P12-I2): activation attempted without the human gate
      # a mandatory gate class requires.
      class UngatedActivationError < ImprovementError; end

      # Terminal (plan §7 P12-I3, invariant 28): rollback could not be proven to
      # restore the previous epoch byte-identically.
      class RollbackIntegrityError < ImprovementError; end

      # Terminal lifecycle refusal: a candidate effect has an unknown outcome
      # and no later phase may treat it as applied or safe to activate.
      class CandidateUnknownError < ImprovementError; end

      # Terminal lifecycle refusal: an approval does not bind the exact
      # candidate, authority, actor, and lifecycle operation being requested.
      class ApprovalDigestError < ImprovementError; end
    end
  end
end
