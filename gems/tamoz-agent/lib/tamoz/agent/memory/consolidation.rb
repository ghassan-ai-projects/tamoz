# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §4 P11-C: Knowledge consolidation — compact, curated, gated. The
      # ONLY model call in the phase, on an explicitly provider-loaded boundary
      # (invariant 11: the admission/retrieval path loads with no provider).
      # The model PROPOSES a candidate; the deterministic gates and the
      # Admission gate (c) decide. Before any rewrite, a preimage is stored;
      # failure leaves prior Knowledge intact and records a rejected candidate
      # naming the failed gate.
      #
      # Deterministic gates (§9): provenance, scope, recurrence, diversity,
      # confidence, taint, budget. Rerun-idempotency keys on the candidate
      # identity so a rerun cannot reinforce the same evidence.
      class Consolidation
        DETERMINISTIC_GATES = %i[provenance scope recurrence diversity confidence taint budget].freeze
        MAX_PREIMAGE_BYTES = 16_384

        def initialize(engine)
          @engine = engine
          @limits = engine.limits
        end

        def consolidate(candidates:, model:, owner:, scopes:, trace: nil)
          unless candidates.length.between?(1, @limits.fetch(:max_consolidation_candidates))
            raise MemoryConsolidationError,
                  "consolidation requires 1..#{@limits.fetch(:max_consolidation_candidates)} candidates"
          end
          unless model.respond_to?(:generate)
            raise MemoryConsolidationError, "consolidation requires a provider-loaded model"
          end

          evaluated = evaluate_gates(candidates)
          evaluated.fetch(:rejected).each { |entry| record_rejected(entry) }

          accepted = evaluated.fetch(:accepted)
          if accepted.empty?
            raise MemoryConsolidationError, "no consolidation candidate passed the deterministic gates"
          end

          # Ingestion checkpoint: a candidate identity already consumed by a
          # prior consolidation run cannot reinforce the same evidence.
          unconsumed = accepted.reject { |entry| consumed?(entry.candidate) }
          if unconsumed.empty?
            raise MemoryConsolidationError, "all consolidation candidates were already consumed"
          end

          candidate = unconsumed.first.candidate
          preimage = store_preimage(candidate)
          proposal = bounded_model_call(model, candidate, accepted)
          validate_proposal!(proposal, candidate, accepted, preimage)
          mark_consumed(candidate)

          proposed = build_proposed_record(proposal, candidate, owner:, scopes:)
          result = @engine.admission.admit_consolidation_candidate(
            record: proposed,
            gates: evaluated.fetch(:passed_gates)
          )
          if result.rejected?
            record_rejected(
              Candidate.new(candidate: proposed, gates: evaluated.fetch(:passed_gates), reason: result.reason)
            )
            raise MemoryConsolidationError, "consolidation candidate rejected: #{result.reason}"
          end
          result
        rescue MemoryConsolidationError
          raise
        rescue StandardError => error
          raise MemoryConsolidationError.new("consolidation failed: #{error.class}"), cause: error
        end

        private

        Candidate = Data.define(:candidate, :gates, :reason)

        def evaluate_gates(candidates)
          accepted = []
          rejected = []
          candidates.each do |candidate|
            gates, reason = deterministic_gates(candidate)
            if reason
              rejected << Candidate.new(candidate:, gates: gates, reason: reason)
            else
              accepted << Candidate.new(candidate:, gates: gates, reason: nil)
            end
          end
          {accepted:, rejected:, passed_gates: DETERMINISTIC_GATES}
        end

        def deterministic_gates(candidate)
          gates = []
          return [gates, "provenance: no source references"] if candidate.source_refs.empty?
          gates << :provenance
          return [gates, "scope: tenant scope missing"] if candidate.scopes.fetch("tenant", "").empty?
          gates << :scope
          # Evidence quality OR recurrence for the risk class: recurrence is
          # measured as the number of distinct supporting sources.
          recurrence = candidate.source_refs.length.to_f
          if recurrence < 2.0 && candidate.klass != :policy
            return [gates, "recurrence: insufficient evidence quality"]
          end
          gates << :recurrence
          if candidate.source_refs.map { |ref| ref["identity"] }.uniq.length < 2
            return [gates, "diversity: single-source synthesis"]
          end
          gates << :diversity
          if candidate.confidence.to_f < 0.5
            return [gates, "confidence: below threshold"]
          end
          gates << :confidence
          return [gates, "taint: recalled content cannot consolidate"] if candidate.recalled?
          gates << :taint
          if candidate.statement.bytesize > @limits.fetch(:max_statement_bytes)
            return [gates, "budget: statement exceeds limit"]
          end
          gates << :budget
          [gates, nil]
        end

        def consumed?(candidate)
          key = checkpoint_key(candidate)
          @engine.store.get(preimage_namespace, key) != nil
        end

        # The preimage: a durable record of the candidate's canonical bytes
        # BEFORE the rewrite, keyed by candidate identity (rerun-idempotency).
        def store_preimage(candidate)
          payload = {
            "candidate_identity" => candidate.digest,
            "candidate_statement" => candidate.statement,
            "source_refs" => candidate.source_refs,
            "preimage_digest" => candidate.digest,
            "recorded_at_ms" => @engine.now_ms
          }
          @engine.store.put(preimage_namespace, checkpoint_key(candidate), payload, if_version: nil)
          payload
        end

        def mark_consumed(candidate)
          payload = {
            "candidate_identity" => candidate.digest,
            "consumed_at_ms" => @engine.now_ms
          }
          @engine.store.put(preimage_namespace, checkpoint_key(candidate), payload, if_version: nil)
        end

        def checkpoint_key(candidate)
          "candidate.#{candidate.digest[0, 40]}"
        end

        def preimage_namespace
          "#{@engine.namespace}.consolidation"
        end

        CONSOLIDATION_SYSTEM = <<~TEXT.freeze
          You are Tamoz's bounded Knowledge consolidation stage. Synthesize the
          supplied Experience candidates into ONE compact Knowledge statement.
          Preserve: every protected entry, every source reference, every
          contradiction, and the 2048-token budget. Return only JSON with keys:
          statement (string), epistemic_kind (reported|inferred), confidence
          (number), contradictions (array), preserved_source_refs (array).
          Never invent evidence. Never label the output observed.
        TEXT

        # ONE bounded model call: the preimage material is bounded to
        # max_consolidation_tokens; the call happens only on a provider-loaded
        # boundary (the caller supplies the model).
        def bounded_model_call(model, candidate, accepted)
          material = accepted.map { |entry| entry.candidate }.map do |entry|
            {"memory_id" => entry.memory_id, "statement" => entry.statement[0, 512], "source_refs" => entry.source_refs.length}
          end
          prompt = JSON.pretty_generate(
            "consolidation_input" => material,
            "budget_tokens" => @limits.fetch(:max_consolidation_tokens)
          )
          response = model.generate(stage: :consolidate, system: CONSOLIDATION_SYSTEM, prompt:)
          parsed = parse_proposal(response)
          parsed
        end

        def parse_proposal(response)
          text = response.is_a?(String) ? response : JSON.generate(response)
          document = Plan.parse_object(text)
          statement = Plan.string(document.fetch("statement"), name: "consolidation statement")
          kind = document.fetch("epistemic_kind").to_sym
          unless %i[reported inferred].include?(kind)
            raise MemoryConsolidationError, "consolidation output must be reported or inferred"
          end
          {
            "statement" => statement,
            "epistemic_kind" => kind.to_s,
            "confidence" => document.fetch("confidence").to_f,
            "contradictions" => Array(document["contradictions"]),
            "preserved_source_refs" => Array(document["preserved_source_refs"])
          }
        rescue KeyError, TypeError => error
          raise MemoryConsolidationError, "invalid consolidation output: #{error.message}"
        end

        def validate_proposal!(proposal, candidate, accepted, preimage)
          # Protected entries survive FIRST (invariant-31 "correcting away the
          # protection"): a policy/constraint-shaped (human approved) source
          # statement must appear in the synthesized statement.
          protected_refs = candidate.source_refs.select { |ref| ref["protected"] == true }
          protected_refs.each do |ref|
            preview = ref["statement_preview"]
            if preview && !proposal.fetch("statement").include?(preview)
              raise MemoryConsolidationError,
                    "consolidation dropped a protected entry (#{ref.fetch("digest")[0, 12]})"
            end
          end

          # Source references survive: every source ref digest cited by the
          # candidate must be preserved in the proposal's preserved_source_refs.
          source_digests = candidate.source_refs.map { |ref| ref.fetch("digest") }
          preserved = proposal.fetch("preserved_source_refs")
          missing_sources = source_digests - preserved
          unless missing_sources.empty?
            raise MemoryConsolidationError,
                  "consolidation dropped source references: #{missing_sources.join(", ")}"
          end

          if proposal.fetch("statement").bytesize > @limits.fetch(:max_statement_bytes)
            raise MemoryConsolidationError, "consolidation output exceeds the statement budget"
          end
          # The preimage is verifiable after any failure.
          stored = @engine.store.get(preimage_namespace, checkpoint_key(candidate))
          unless stored && stored.value.fetch("preimage_digest") == candidate.digest
            raise MemoryConsolidationError, "consolidation preimage is not verifiable"
          end
        end

        def build_proposed_record(proposal, candidate, owner:, scopes:)
          MemoryRecord.new(
            memory_id: MemoryRecordDigest.identity(proposal.fetch("statement")),
            record_version: 1,
            layer: :knowledge,
            klass: candidate.klass == :policy ? :policy : :procedure,
            state: :candidate,
            statement: proposal.fetch("statement"),
            epistemic_kind: proposal.fetch("epistemic_kind").to_sym,
            source_refs: candidate.source_refs,
            owner:,
            actor: owner,
            scopes:,
            sensitivity: candidate.sensitivity,
            confidence: proposal.fetch("confidence"),
            confidence_method: "consolidation",
            contradiction_set_id: proposal.fetch("contradictions").empty? ? nil : Digest::SHA256.hexdigest(proposal.fetch("contradictions").join("\0")),
            created_by: {"surface" => "consolidation"},
            compatibility: {"graph_version" => "1", "behavior_version" => SessionNodes::BEHAVIOR_VERSION},
            transition: {
              "actor" => owner.to_s,
              "authority" => "consolidation",
              "reason" => "consolidation synthesis",
              "evidence" => {"preimage" => candidate.digest},
              "policy_version" => "1",
              "timestamp" => @engine.now_ms,
              "trace_id" => SecureRandom.uuid
            },
            created_at_ms: @engine.now_ms
          )
        end

        def record_rejected(entry)
          candidate = entry.candidate
          rejected = candidate.with(
            state: :rejected,
            rejection_reason: "consolidation_gate: #{entry.reason}"
          )
          @engine.repository.append(
            record: rejected,
            index: @engine.index_for(rejected),
            expected_version: nil,
            sensitive: rejected.sensitive?
          )
        rescue StandardError
          nil
        end
      end
    end
  end
end
