# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11-W: Wisdom — evaluated strategies only. Promotion pipeline
      # (plan §4): knowledge/experience evidence → candidate → public
      # development evaluation → protected holdout → authority gate → behavior
      # version → monitor/rollback.
      #
      # Hard gates (invariant 28/29):
      # * the candidate cannot see the holdout, evaluator, or case-level
      #   outcome (asserted at data-flow level — the candidate record never
      #   carries holdout content);
      # * capability/security/approval/evaluator/prompt-hierarchy/procedural-
      #   policy/code changes require a human gate;
      # * v1 scope: at most ONE promoted planning/routing heuristic candidate
      #   (the registry's singleton pending transition + one active
      #   transition); nothing self-approved;
      # * Wisdom never grants credentials or permission — the promoted record
      #   RECOMMENDS; plan review/authorization/approval/effect wrappers still
      #   decide.
      class Wisdom
        ONE_CANDIDATE_LIMIT = 1

        def initialize(engine)
          @engine = engine
          @registry = engine.transitions
        end

        # Promote ONE candidate through the full gated pipeline. All
        # provider-loaded work (development evaluation, holdout evaluation)
        # happens on the caller's explicit boundary; nothing here decides
        # authority.
        def promote(
          candidate:,                 # the Wisdom candidate MemoryRecord
          development_evaluation:,    # {evidence_digest:, passed:, outcomes_digest:}
          holdout:,                   # {path:, verifier:} — protected partition
          human_gate:,                # {required: bool, evidence: nil|String}
          behavior_snapshot:,         # bounded immutable snapshot (prompt block)
          behavior_version_after:,    # "tamoz.agent.session/2"
          actor: "tamoz.agent.memory.wisdom"
        )
          assert_candidate_shapes!(candidate)
          assert_no_active_wisdom!
          assert_authority_gates!(candidate, development_evaluation, human_gate)

          # The candidate never sees the holdout: the holdout partition is read
          # only by the distinct verifier principal, AFTER promotion.
          holdout_evidence = verify_holdout(holdout, candidate)
          development_evidence = development_evaluation.fetch(:evidence_digest)
          evidence = {"development" => development_evidence, "holdout" => holdout_evidence}

          evidence_digest = Digest::SHA256.hexdigest(
            JSON.generate(Tamoz::Core.canonical(evidence))
          )

          transition, reserved = @registry.record(
            kind: :wisdom_promotion,
            candidate_id: candidate.memory_id,
            candidate_digest: candidate.digest,
            behavior_snapshot:,
            behavior_version_after:,
            promotion_evidence_digest: evidence_digest,
            human_gate_evidence: human_gate.fetch(:evidence),
            created_by: actor
          )
          {
            "transition" => transition,
            "reserved_version" => reserved,
            "evidence" => evidence,
            "recommendation_only" => true
          }
        end

        private

        def assert_candidate_shapes!(candidate)
          unless candidate.layer == :wisdom && candidate.state == :candidate
            raise MemoryPolicyError, "wisdom candidate must be a candidate Wisdom record"
          end
          if candidate.statement.bytesize > BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES
            raise MemoryPolicyError, "wisdom candidate exceeds the snapshot bound"
          end
          if candidate.epistemic_kind == :observed
            raise MemoryPolicyError, "wisdom cannot be labeled observed"
          end
          if candidate.owner.to_s.empty?
            raise MemoryPolicyError, "wisdom candidate requires an owner"
          end
        end

        def assert_no_active_wisdom!
          active = @registry.active
          if active.fetch("active_transition_id") && @registry.pending_transition_id
            raise MemoryPolicyError, "one promoted candidate already active or pending"
          end
          if @registry.pending_transition_id
            raise MemoryPolicyError, "a promotion is already pending"
          end
        end

        # Capability/security/approval/evaluator/prompt-hierarchy/procedural-
        # policy/code changes require a human gate. A planning/routing
        # heuristic with the full pipeline may pass with a recorded authority
        # (the pipeline's own gates); nothing self-approves.
        def assert_authority_gates!(candidate, development_evaluation, human_gate)
          sensitive_change = candidate.klass == :constraint ||
                             candidate.klass == :policy ||
                             candidate.klass == :profile
          if sensitive_change && human_gate.fetch(:required) != true
            raise MemoryPolicyError,
                  "promotion affecting capability/security/approval/evaluator/" \
                  "prompt-hierarchy/procedural-policy requires a human gate"
          end
          unless human_gate.fetch(:evidence).to_s.start_with?("human:")
            raise UnverifiedTransitionError, "human gate evidence is missing"
          end
          unless development_evaluation.fetch(:passed) == true
            raise UnverifiedTransitionError, "development evaluation did not pass"
          end
          if development_evaluation.fetch(:outcomes_digest).to_s.empty?
            raise UnverifiedTransitionError, "development evaluation outcomes are missing"
          end
        end

        # The holdout is outside the promotion runner's root at mode 0o700 and
        # is read only by the distinct verifier principal. The candidate never
        # receives holdout content: the evidence digest covers the verifier's
        # outcome, never the holdout bytes.
        def verify_holdout(holdout, candidate)
          verifier = holdout.fetch(:verifier)
          outcome = verifier.call(holdout.fetch(:path), candidate.digest)
          unless outcome.is_a?(Hash) && outcome.fetch("passed") == true
            raise UnverifiedTransitionError, "protected holdout did not pass"
          end

          Digest::SHA256.hexdigest(
            JSON.generate(Tamoz::Core.canonical(outcome.reject { |k, _| k == "content" }))
          )
        end
      end
    end
  end
end
