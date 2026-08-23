# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §3/C7 + §4 P11-A/P11-C: deterministic admission. NO model call
      # decides admission; a model may *propose* a candidate (consolidation),
      # never admit one. The deterministic gate accepts a candidate only when
      # one of:
      #
      #   (a) episode      — a completed bounded episode with an independently
      #                      observed Outcome (P11-A);
      #   (b) owner_request — an explicit authorized owner request (P11-C fast
      #                      path, with its three negatives);
      #   (c) consolidation — a consolidation candidate that passed the
      #                      deterministic gates (P11-C §9).
      #
      # Default is rejection when ownership/scope/sensitivity is unknown; a
      # rejected admission is a durable `state: :rejected` record with the
      # rejection reason, so rerun-idempotency keys on candidate identity.
      class Admission
        REJECT_REASONS = %w[
          gate_missing
          unbounded_statement
          secret_shaped
          missing_provenance
          speculation_as_fact
          recalled_as_new
          unknown_ownership
          unknown_scope
          unknown_sensitivity
          policy_instruction_from_untrusted
          duplicate_identity
        ].freeze

        # Typed result value, never an exception (invariant 17).
        AdmissionResult = Data.define(:record, :accepted, :rejected, :reason) do
          def initialize(record: nil, accepted: false, rejected: false, reason: nil)
            super(record:, accepted:, rejected:, reason:)
          end

          def accepted? = accepted
          def rejected? = rejected
        end

        def initialize(engine)
          @engine = engine
        end

        # Gate (a): a completed bounded episode with an independently observed
        # Outcome. `episode` carries task/session identity, accepted plan
        # digest, key observations, decisions, effect receipts, the observed
        # outcome, corrections/human feedback, and links to the protected
        # trajectory — NEVER a raw transcript or recalled content.
        #
        # T5.3: an episode is :observed ONLY with an authenticated
        # reconciled-outcome reference (`reconciled_outcome:` + the
        # `verify_source_authority` callable). The reference names the stream's
        # reconciled Outcome — the independent observer Tamoz alone cannot be.
        # Absent: the episode admits as :reported (self-certified turns). A
        # CLAIMED reference that does not verify is REFUSED — there is no
        # silent downgrade of a forged claim.
        def admit_episode(episode:, owner:, actor: nil, reconciled_outcome: nil,
                          verify_source_authority: nil)
          max = MemoryLimits.fetch(:max_statement_bytes)
          if episode[:statement] && episode[:statement].bytesize > max
            return oversized_rejected(episode[:statement], owner:, actor:)
          end

          record = build_from_episode(
            episode, owner:, actor:, reconciled_outcome:, verify_source_authority:
          )
          # Anti self-ingestion (P11-A): recalled content is excluded as new
          # Experience evidence. A recall trace mark is not enough — the
          # admission boundary itself rejects the loop (probe P11-A2).
          if episode[:recalled_memory]
            record = record.with(
              transition: (record.transition || {}).merge("recalled" => true)
            )
          end
          admit(record, gate: :episode, evidence: episode_evidence(episode))
        end

        # Gate (b): the explicit owner fast path (P11-C). An authorized owner
        # request may enter Knowledge directly as :reported/:prescribed with
        # conflict and policy checks. Three negatives are structural: it cannot
        # label :observed, cannot create Wisdom, and cannot preserve a secret
        # contrary to policy or grant capability/approval.
        def admit_owner_request(statement:, owner:, authority:, layer: :knowledge,
                                klass: :preference, scopes:, sensitivity: :internal,
                                epistemic_kind: :reported,
                                contradiction_check: nil, now: nil)
          negatives = []
          negatives << "owner_request_cannot_label_observed" if epistemic_kind == :observed
          negatives << "owner_request_cannot_create_wisdom" if layer == :wisdom
          negatives << "owner_request_cannot_grant_capability" if klass == :constraint && statement.match?(/approv|allowed_tools|permission/i)
          if Surface.secret_shaped?(statement)
            negatives << "secret_contrary_to_policy"
          end
          if authority.to_s != "owner"
            negatives << "authority_must_be_owner"
          end
          unless %i[reported prescribed].include?(epistemic_kind)
            negatives << "owner_request_must_be_reported_or_prescribed"
          end
          unless negatives.empty?
            return AdmissionResult.new(
              rejected: true,
              reason: "owner_fast_path: #{negatives.join(", ")}"
            )
          end

          record = MemoryRecord.new(
            memory_id: MemoryRecordDigest.identity(statement),
            record_version: 1,
            layer:,
            klass: klass == :constraint ? :constraint : :preference,
            state: :active,
            statement:,
            epistemic_kind:,
            source_refs: [{
              "identity" => "owner-request",
              "digest" => Digest::SHA256.hexdigest(statement),
              "observed_at" => (now || Time.now).to_i
            }],
            owner:,
            actor: owner,
            scopes:,
            sensitivity:,
            disclosure_policy: "default",
            valid_from: (now || Time.now).to_i,
            created_by: {"surface" => "owner_fast_path"},
            compatibility: {"graph_version" => "1", "behavior_version" => BEHAVIOR_VERSION},
            transition: transition("owner", "owner fast path admission", evidence: {"authority" => authority.to_s}),
            created_at_ms: @engine.now_ms
          )
          conflict = contradiction_check && contradiction_check.call(record)
          if conflict
            return AdmissionResult.new(
              rejected: true,
              reason: "contradiction: #{conflict}"
            )
          end

          admit(record, gate: :owner_request, evidence: {"authority" => authority.to_s})
        end

        # Gate (c): a consolidation candidate that passed the deterministic
        # gates. `gates` names which §9 gates already passed (provenance,
        # scope, recurrence, diversity, confidence, taint, budget).
        def admit_consolidation_candidate(record:, gates:)
          unless record.layer == :knowledge && record.state == :candidate
            return AdmissionResult.new(
              rejected: true,
              reason: "consolidation candidate must be a candidate Knowledge record"
            )
          end
          missing = %i[provenance scope recurrence diversity confidence taint budget] - gates
          unless missing.empty?
            return AdmissionResult.new(
              rejected: true,
              reason: "consolidation gates missing: #{missing.join(", ")}"
            )
          end
          if record.epistemic_kind == :observed
            return AdmissionResult.new(
              rejected: true,
              reason: "consolidation cannot label observed"
            )
          end
          if record.source_refs.empty?
            return AdmissionResult.new(
              rejected: true,
              reason: "consolidation candidate must preserve source references"
            )
          end

          admit(record, gate: :consolidation, evidence: {"gates" => gates.map(&:to_s)})
        end

        private

        # An oversized candidate is durably rejected, never truncated silently:
        # the durable rejected record carries a bounded rejection notice keyed
        # to the candidate's content digest (rerun-idempotency preserved).
        def oversized_rejected(statement, owner:, actor: nil)
          max = MemoryLimits.fetch(:max_statement_bytes)
          notice = "ADMISSION REJECTED: statement of #{statement.bytesize} bytes " \
                   "exceeds the #{max} byte limit"
          record = MemoryRecord.new(
            memory_id: MemoryRecordDigest.identity(statement),
            record_version: 1,
            layer: :experience,
            klass: :episode,
            state: :rejected,
            statement: notice,
            epistemic_kind: :reported,
            source_refs: [],
            owner:,
            actor: actor || owner,
            scopes: {"tenant" => "unknown", "user" => "unknown", "project" => "unknown", "session" => "unknown"},
            sensitivity: :internal,
            rejection_reason: "unbounded_statement",
            transition: transition(actor || owner, "rejected at admission", evidence: {"gate" => "episode"}),
            created_at_ms: @engine.now_ms
          )
          store_rejected(record)
          AdmissionResult.new(record:, rejected: true, reason: "unbounded_statement")
        end

        def admit(record, gate:, evidence:)
          # Rerun-idempotency keys on candidate identity: a memory_id that
          # already exists is durably rejected, never duplicated.
          if @engine.repository.current_version(@engine.namespace, record.layer.to_s, record.memory_id)
            rejected = record.with(
              state: :rejected,
              rejection_reason: "duplicate_identity",
              transition: record.transition || transition(
                record.actor || "admission",
                "duplicate candidate identity",
                evidence: {"gate" => gate.to_s, **evidence}
              )
            )
            return AdmissionResult.new(record: rejected, rejected: true, reason: "duplicate_identity")
          end

          reason = reject_reason(record, gate:)
          unless reason.nil?
            rejected = record.with(
              state: :rejected,
              rejection_reason: reason,
              transition: record.transition || transition(
                record.actor || "admission",
                "rejected at admission",
                evidence: {"gate" => gate.to_s, **evidence}
              )
            )
            store_rejected(rejected)
            return AdmissionResult.new(record: rejected, rejected: true, reason:)
          end

          activated = record.with(
            state: :active,
            transition: transition(
              record.actor || record.owner,
              "admitted",
              evidence: {"gate" => gate.to_s, **evidence}
            )
          )
          append(activated)
          AdmissionResult.new(record: activated, accepted: true)
        end

        def reject_reason(record, gate:)
          return "unbounded_statement" if record.statement.bytesize > MemoryLimits.fetch(:max_statement_bytes)
          return "secret_shaped" if Surface.secret_shaped?(record.statement)
          if record.epistemic_kind == :observed &&
             (record.statement.match?(/probably|likely|seems|maybe|might/i) ||
              record.statement.end_with?("?"))
            return "speculation_as_fact"
          end
          if record.source_refs.empty? && record.epistemic_kind != :prescribed
            return "missing_provenance"
          end
          if record.transition && record.transition["recalled"] == true
            return "recalled_as_new"
          end
          if record.scopes.fetch("tenant", "").empty?
            return "unknown_scope"
          end
          if record.owner.to_s.empty?
            return "unknown_ownership"
          end
          if record.sensitivity.nil?
            return "unknown_sensitivity"
          end
          if record.layer == :knowledge &&
             record.epistemic_kind == :prescribed &&
             !record.transition && record.owner == "untrusted"
            return "policy_instruction_from_untrusted"
          end

          nil
        end

        def build_from_episode(episode, owner:, actor: nil, reconciled_outcome: nil,
                               verify_source_authority: nil)
          plan_digest = episode.fetch(:plan_digest)
          task = episode.fetch(:task)
          observed = episode.fetch(:observed_outcome)
          unless observed.is_a?(Hash)
            raise MemoryPolicyError, "observed_outcome must be an object"
          end

          # Canonicalize to string keys ONCE: production episodes are
          # string-keyed (session_memory), workers and tests may use symbols.
          # Every downstream read uses the string form, so a symbol-keyed
          # outcome never loses its values to a symbol-only fetch.
          observed = observed.transform_keys(&:to_s)
          # T5.3: an episode is :observed ONLY with an authenticated
          # reconciled-outcome reference. The independently_observed boolean
          # has NO power — a bare truthy flag is a self-certified claim and
          # admits as :reported (regression-pinned). A CLAIMED reference that
          # does not authenticate is refused: the admission boundary never
          # silently downgrades a forged claim to :reported.
          reason = VerifiedOutcomeReference.reason(
            reconciled_outcome, episode:, verify_source_authority:
          )
          if reason
            unless reconciled_outcome.nil?
              raise MemoryPolicyError, "admission refused: #{reason}"
            end

            kind = :reported
          else
            kind = :observed
          end
          # An explicitly provided statement (key observations + decisions +
          # corrections) is the memory content; otherwise a bounded summary of
          # the episode's grounded parts is built. Never a transcript, never
          # recalled content.
          statement = if episode[:statement]
                        episode.fetch(:statement)
                      else
                        build_statement(task, observed, episode, kind)
                      end
          episode_ref = {
            "identity" => "episode:#{episode.fetch(:session_id)}",
            "digest" => plan_digest,
            "observed_at" => episode.fetch(:completed_at, Time.now.to_i)
          }
          %i[traceparent tracestate].each do |key|
            value = episode[key]
            episode_ref[key.to_s] = value if value
          end
          source_refs = [episode_ref]
          # T5.3: the :observed record cites the Outcome id, command id,
          # source authority, and reconciliation version, so provenance
          # survives the gap between the episode and the Friday outcome.
          if kind == :observed
            source_refs << VerifiedOutcomeReference.provenance(reconciled_outcome)
          end
          MemoryRecord.new(
            memory_id: MemoryRecordDigest.identity(statement),
            record_version: 1,
            layer: :experience,
            klass: :episode,
            state: :candidate,
            statement:,
            epistemic_kind: kind,
            source_refs:,
            owner:,
            actor: actor || owner,
            scopes: episode.fetch(:scopes),
            sensitivity: episode.fetch(:sensitivity, :internal),
            disclosure_policy: "default",
            confidence: observed.fetch("confidence", 0.8),
            confidence_method: "observed_outcome",
            valid_from: episode.fetch(:completed_at, Time.now.to_i),
            valid_until: episode[:valid_until],
            created_by: {"surface" => "episode_admission", "session_id" => episode.fetch(:session_id)},
            compatibility: {"graph_version" => "1", "behavior_version" => BEHAVIOR_VERSION},
            transition: transition(actor || owner, "episode admission", evidence: {"session_id" => episode.fetch(:session_id)}),
            created_at_ms: @engine.now_ms
          )
        end

        def build_statement(task, observed, episode, kind)
          outcome = observed.fetch("outcome", "completed")
          # A :reported record must not claim its outcome was observed; the
          # label says which epistemic kind the statement is bound to.
          label = kind == :observed ? "observed outcome" : "reported outcome"
          # Bounded, grounded: the task, the outcome, and the effect receipts —
          # never a transcript, never recalled content.
          parts = [
            "Episode for task #{task}",
            "#{label}: #{outcome}",
            "decisions: #{Array(episode.fetch(:decisions, [])).join("; ")}",
            "corrections: #{Array(episode.fetch(:corrections, [])).join("; ")}"
          ]
          parts.join(". ").strip[0, MemoryLimits.fetch(:max_statement_bytes) - 1]
        end

        def episode_evidence(episode)
          observed = episode.fetch(:observed_outcome, {})
          observed = observed.transform_keys(&:to_s) if observed.is_a?(Hash)
          {
            "session_id" => episode.fetch(:session_id),
            "plan_digest" => episode.fetch(:plan_digest),
            "observed_outcome" => observed["outcome"]
          }
        end

        def transition(actor, reason, evidence: {})
          {
            "actor" => actor.to_s,
            "authority" => "deterministic_admission",
            "reason" => reason,
            "evidence" => evidence,
            "policy_version" => "1",
            "timestamp" => @engine.now_ms,
            "trace_id" => SecureRandom.uuid
          }
        end

        def append(record)
          @engine.repository.append(
            record: record,
            index: @engine.index_for(record),
            expected_version: nil,
            sensitive: record.sensitive?
          )
        end

        def store_rejected(record)
          @engine.repository.append(
            record: record,
            index: @engine.index_for(record),
            expected_version: nil,
            sensitive: record.sensitive?
          )
        rescue StandardError
          # A rejected admission is durable evidence, but a storage failure
          # must not fabricate a durable rejection. The rejection is still the
          # returned value; the operator sees the storage failure.
          nil
        end
      end

      # Deterministic memory identity: sha256 of the canonical statement. Used
      # for admission dedup and rerun-idempotency on candidate identity.
      module MemoryRecordDigest
        DIGEST_DOMAIN = "tamoz.agent.memory.record.v1\n"

        module_function

        def identity(statement)
          "mem.#{Tamoz::Core.digest(DIGEST_DOMAIN, statement.to_s).delete_prefix('sha256:')[0, 40]}"
        end
      end
    end
  end
end
