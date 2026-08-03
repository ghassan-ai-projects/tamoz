# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Improvement
      # P12-I3 (plan §7): activate the evaluated heuristic candidate as a new
      # behavior/cache epoch, and roll it back byte-identically.
      #
      # **There is no second activation mechanism here.** Every state change
      # goes through the P11-W-owned `Memory::TransitionRegistry` —
      # `#record` (snapshot + control-record CAS), `#claim`, `#finalize`,
      # `#active`, `#snapshot_for` — with `kind: :heuristic_promotion`. The
      # claim happens in `SessionNodes#claim_behavior_transition` at the FIRST
      # INTAKE OF A THREAD (DR-1 revision 4); the apply is the intake checkpoint
      # commit; the finalize is `SessionNodes#finalize_behavior_claim`. This
      # class only *records* a transition and *verifies* what the shared
      # machinery did with it. P11-W's memory-derived strategy and P12-I's
      # trajectory-derived heuristic therefore share ONE behavior-version
      # record and neither can bump it independently: the control record's
      # single `pending_transition_id` serializes them.
      class Promotion
        ACTOR_DOMAIN = "tamoz.agent.improvement.promotion.v1\n"
        KIND = :heuristic_promotion
        # Plan §10 deferral, enforced: v1 carries at most one live heuristic.
        ONE_LIVE_HEURISTIC = 1

        def initialize(engine)
          @engine = engine
          @registry = engine.transitions
        end

        # Record the promotion transition. Nothing activates here: the returned
        # transition is `:recorded` and stays pending until a NEW thread's first
        # intake claims it. An in-flight thread never adopts it.
        def promote(
          candidate:,            # Improvement::Heuristic
          provenance:,           # Improvement::Provenance
          report:,               # the sealed evaluation report (tamoz-evals)
          human_gate_evidence:,  # "human:<actor>" approval artifact
          actor:,                # the promoting principal
          evidence_resolver:,    # callable -> the report as the EVALUATOR stored it
          gate_classes: EvaluationReport::HEURISTIC_GATE_CLASSES
        )
          candidate.assert_bounded!
          body = EvaluationReport.verify!(report)
          assert_evidence_resolves!(body, evidence_resolver)
          assert_not_self_promoting!(candidate, body, actor)
          EvaluationReport.assert_human_gate!(gate_classes:, evidence: human_gate_evidence)

          decision = EvaluationReport.decide(body)
          unless decision.fetch("passed")
            raise ImprovementPolicyError,
                  "evaluation did not clear the promotion gates: " \
                  "#{decision.fetch("reasons").join("; ")}"
          end

          provenance.assert_complete!
          assert_provenance_binds!(candidate, provenance, body)
          assert_one_live_heuristic!

          before = @registry.active.fetch("active_version")
          after = provenance.affected_behavior.fetch("behavior_version_after")
          assert_forward!(before, after)

          transition, reserved = @registry.record(
            kind: KIND,
            candidate_id: candidate.heuristic_id,
            candidate_digest: candidate.digest,
            behavior_snapshot: candidate.snapshot,
            behavior_version_after: after,
            promotion_evidence_digest: EvaluationReport.seal(body),
            human_gate_evidence:,
            created_by: String(actor)
          )
          {
            "transition" => transition,
            "reserved_version" => reserved,
            "decision" => decision,
            "provenance_digest" => provenance.digest,
            "injection_digest" => self.class.injection_digest(candidate.snapshot),
            "activated" => false
          }
        end

        # Roll back the active heuristic epoch. Per DR-1 §7 a rollback is a
        # FRESH serialized transition from the current active version to the
        # PRIOR snapshot digest: the version allocator never moves backward, but
        # the SERVED injection region returns to exactly the prior bytes.
        #
        # The rollback is refused unless the prior snapshot can still be
        # rebuilt from the Store, so a rollback never silently lands on
        # something that merely resembles the old epoch.
        def rollback(reason:, actor:, human_gate_evidence:)
          active = @registry.active
          transition_id = active.fetch("active_transition_id")
          unless transition_id
            raise RollbackIntegrityError, "no active transition to roll back"
          end

          current = @registry.transition(transition_id)
          unless current && current.kind == KIND
            raise RollbackIntegrityError,
                  "the active transition #{transition_id} is not a heuristic promotion"
          end

          target = current.rollback_target || {}
          target_digest = target["snapshot_digest"]
          if String(target_digest).empty?
            raise RollbackIntegrityError,
                  "transition #{transition_id} has no prior snapshot to restore; the epoch " \
                  "before it injected nothing and cannot be restored by a snapshot transition"
          end

          snapshot = @registry.snapshot_for(target_digest)
          unless snapshot
            raise RollbackIntegrityError,
                  "the prior behavior snapshot #{target_digest} is no longer in the Store; " \
                  "rollback cannot be proven byte-identical"
          end

          EvaluationReport.assert_human_gate!(
            gate_classes: EvaluationReport::HEURISTIC_GATE_CLASSES,
            evidence: human_gate_evidence
          )

          before = active.fetch("active_version")
          after = self.class.successor_version(before)
          # Identity of the ROLLBACK candidate: content-addressed on what is
          # being undone, so a retried rollback is idempotent at the row level
          # and a second, different rollback is a different row.
          candidate_digest = "sha256:#{Digest::SHA256.hexdigest(
            ACTOR_DOMAIN + JSON.generate(["rollback", transition_id, before, target_digest])
          )}"

          transition, reserved = @registry.record(
            kind: KIND,
            candidate_id: "rollback.#{current.candidate_id}",
            candidate_digest:,
            behavior_snapshot: snapshot,
            behavior_version_after: after,
            promotion_evidence_digest: current.promotion_evidence_digest,
            human_gate_evidence:,
            created_by: String(actor)
          )
          {
            "transition" => transition,
            "reserved_version" => reserved,
            "reason" => String(reason),
            "rolled_back_transition_id" => transition_id,
            "target_snapshot_digest" => target_digest,
            "injection_digest" => self.class.injection_digest(snapshot)
          }
        end

        # Post-activation proof (plan §7 P12-I3, invariant 28): the epoch now
        # active must serve BYTE-IDENTICAL injection content to the epoch named
        # by `expected_snapshot_digest`. This compares bytes, not record values:
        # the snapshot is re-read from the Store and the delimited injection
        # region is re-rendered and digested.
        def assert_rolled_back_byte_identical!(expected_snapshot_digest:, expected_injection_digest:)
          active = @registry.active
          actual_digest = active.fetch("active_snapshot_digest")
          unless actual_digest == expected_snapshot_digest
            raise RollbackIntegrityError,
                  "rollback left snapshot #{actual_digest.inspect}, expected " \
                  "#{expected_snapshot_digest.inspect}"
          end

          snapshot = @registry.snapshot_for(actual_digest)
          unless snapshot
            raise RollbackIntegrityError, "the restored snapshot #{actual_digest} is unreadable"
          end

          actual_injection = self.class.injection_digest(snapshot)
          unless actual_injection == expected_injection_digest
            raise RollbackIntegrityError,
                  "the restored injection region digests #{actual_injection}, expected " \
                  "#{expected_injection_digest}; the rollback is not byte-identical"
          end
          {
            "active_version" => active.fetch("active_version"),
            "active_snapshot_digest" => actual_digest,
            "injection_digest" => actual_injection,
            "byte_identical" => true
          }
        end

        # The canonical bytes of the delimited injection region the planning
        # prompt serves — the SAME shape `SessionNodes#planning_context_for`
        # builds, so this digest is over what the model actually sees, not over
        # a parallel rendering.
        def self.injection_region(snapshot)
          JSON.generate(
            Tamoz::Core.canonical(
              "marker" => Memory::BehaviorTransition::SNAPSHOT_MARKERS,
              "content" => snapshot
            )
          )
        end

        def self.injection_digest(snapshot)
          "sha256:#{Digest::SHA256.hexdigest(injection_region(snapshot))}"
        end

        # "tamoz.agent.session/3" -> "tamoz.agent.session/4". The allocator only
        # moves forward, including through a rollback (DR-1 §7).
        def self.successor_version(version)
          text = String(version)
          prefix, _, ordinal = text.rpartition("/")
          unless !prefix.empty? && ordinal.match?(/\A\d+\z/)
            raise ImprovementPolicyError, "cannot allocate a successor to #{text.inspect}"
          end

          "#{prefix}/#{ordinal.to_i + 1}"
        end

        private

        # DR-1 §6 / plan §7 hard-zero. The seal alone proves only that a report
        # is self-consistent — anyone able to CONSTRUCT a report could also seal
        # it, because the seal is a digest and not a keyed MAC. What makes the
        # gate real is the resolution step: the report presented for promotion
        # must be byte-identical (by seal) to the artifact the EVALUATOR wrote
        # into its own protected output partition, which the candidate's
        # capability grant cannot reach. A forged-but-correctly-sealed report
        # fails here.
        def assert_evidence_resolves!(body, resolver)
          unless resolver.respond_to?(:call)
            raise ImprovementPolicyError,
                  "promotion requires an evidence resolver for the evaluator's stored report"
          end

          stored = resolver.call(EvaluationReport.seal(body))
          unless stored.is_a?(Hash)
            raise EvaluatorTamperError,
                  "the evaluator's stored report could not be resolved; a candidate cannot " \
                  "supply its own evaluation evidence"
          end

          resolved = EvaluationReport.verify!(stored)
          return if EvaluationReport.seal(resolved) == EvaluationReport.seal(body)

          raise EvaluatorTamperError,
                "the presented evaluation report does not match the evaluator's stored artifact"
        end

        # Invariant 34 / plan §1 hard-zero. The promoting actor must be a third
        # party: not the candidate, not the generator that produced it, and not
        # the evaluator that scored it.
        def assert_not_self_promoting!(candidate, body, actor)
          name = String(actor)
          raise ImprovementPolicyError, "promotion requires an actor" if name.empty?

          generator = String(body.fetch("generator_principal"))
          evaluator = String(body.fetch("evaluator_principal"))
          if name == generator || name == String(candidate.generator_principal)
            raise SelfPromotionError,
                  "the generating principal (#{name}) may not promote its own candidate"
          end
          if name == evaluator
            raise SelfPromotionError,
                  "the evaluating principal (#{name}) may not promote the candidate it scored"
          end
          if name == candidate.heuristic_id || name == candidate.digest
            raise SelfPromotionError, "a candidate may not promote itself"
          end
          return if String(candidate.generator_principal) == generator

          raise EvaluatorTamperError,
                "the report's generator principal (#{generator}) is not the candidate's " \
                "(#{candidate.generator_principal})"
        end

        # The provenance must BIND to the exact artifacts being promoted. A
        # provenance that is complete but describes a different candidate,
        # report, or snapshot is worse than no provenance.
        def assert_provenance_binds!(candidate, provenance, body)
          artifacts = provenance.artifact_digests
          unless artifacts.fetch("candidate_digest") == candidate.digest
            raise ProvenanceIncompleteError,
                  "provenance candidate_digest does not bind the promoted candidate"
          end
          expected_snapshot = Memory::BehaviorTransition.snapshot_digest(candidate.snapshot)
          unless artifacts.fetch("snapshot_digest") == expected_snapshot
            raise ProvenanceIncompleteError,
                  "provenance snapshot_digest does not bind the promoted snapshot"
          end

          lineage = provenance.evaluation_lineage
          unless lineage.fetch("report_digest") == EvaluationReport.seal(body)
            raise ProvenanceIncompleteError,
                  "provenance report_digest does not bind the verified evaluation report"
          end
          unless lineage.fetch("evaluator_principal") == body.fetch("evaluator_principal") &&
                 lineage.fetch("generator_principal") == body.fetch("generator_principal")
            raise ProvenanceIncompleteError,
                  "provenance evaluation lineage principals do not match the report"
          end
          return if provenance.rollback_target.fetch("behavior_version") ==
                    @registry.active.fetch("active_version")

          raise ProvenanceIncompleteError,
                "provenance rollback_target names #{provenance.rollback_target.fetch("behavior_version").inspect}, " \
                "but the active behavior version is #{@registry.active.fetch("active_version").inspect}"
        end

        # Plan §10: v1 promotes at most one heuristic AT A TIME. "Live" means
        # a heuristic epoch that has not been rolled back: once the first
        # candidate has telemetry and is rolled back (the rollback rides the
        # same record type with a `rollback.` candidate id), a follow-up round
        # may promote the next one. Counting rows in `recorded|claimed|activated`
        # forever would make the "one reversible behavior candidate" contract
        # irreversible — a rolled-back candidate is not a live one.
        def assert_one_live_heuristic!
          rows = @engine.store.each(Memory::BehaviorTransition::TRANSITIONS_NAMESPACE, limit: 64).to_a
          rolled_back = rows.filter_map do |entry|
            value = entry.value
            next unless value.is_a?(Hash) && value["kind"] == KIND.to_s

            candidate = String(value["candidate_id"])
            next unless candidate.start_with?("rollback.")

            candidate.delete_prefix("rollback.")
          end
          live = rows.count do |entry|
            value = entry.value
            next false unless value.is_a?(Hash) && value["kind"] == KIND.to_s
            # A rollback row is the undoing of a heuristic, not a second one.
            next false if String(value["candidate_id"]).start_with?("rollback.")
            # A rolled-back candidate is no longer live, so a follow-up round
            # may promote the next candidate after the first has telemetry.
            next false if rolled_back.include?(String(value["candidate_id"]))

            %w[recorded claimed activated].include?(value["status"])
          end
          return if live < ONE_LIVE_HEURISTIC

          raise ImprovementPolicyError,
                "a heuristic promotion is already live (#{live}); v1 carries at most " \
                "#{ONE_LIVE_HEURISTIC}"
        end

        def assert_forward!(before, after)
          _, _, from = String(before).rpartition("/")
          _, _, to = String(after).rpartition("/")
          return if from.match?(/\A\d+\z/) && to.match?(/\A\d+\z/) && to.to_i > from.to_i

          raise ImprovementPolicyError,
                "behavior version #{after.inspect} does not advance #{before.inspect}"
        end
      end
    end
  end
end
