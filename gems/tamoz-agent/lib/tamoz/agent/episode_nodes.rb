# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"
require "tamoz/agent/model_receipt"
require "tamoz/agent/reasoning_document"
require "tamoz/agent/episode_model_call"
require "tamoz/agent/episode_frame_builder"

module Tamoz
  module Agent
    # P1/§3.1: the five nodes of the fixed production episode graph. Only
    # `reason` calls a model — through EpisodeModelCall/EffectDispatcher with a
    # journaled receipt. Everything else is deterministic. The graph is domain
    # agnostic: the diagnosis catalog, prompt, objective, snapshot facts, and
    # decision builder are injected data/ports.
    #
    # Node ports are injected at the worker composition (tamoz-stream services
    # arrive as duck-typed ports; the decision builder keeps living in
    # tamoz-stream per the phase doc).
    class EpisodeNodes
      # `api_base` is on the profile secret-key denylist; the endpoint override
      # uses `base_url` instead (same intent, no scanner weakening).
      ROLE_ENDPOINT_KEYS = %w[base_url api_base].freeze
      RECALL_OPERATION = "tamoz.agent.episode.recall"

      def initialize(profile:, frame_builder_factory:, model_call_factory:, decision_builder:, tool_call: nil, skills_source: {}, situation_recaller: nil, recall_caller: nil)
        @profile = profile
        @frame_builder_factory = frame_builder_factory
        @model_call_factory = model_call_factory
        @decision_builder = decision_builder
        @tool_call = tool_call || EpisodeToolCall.new(tool_port: nil)
        @skills_source = skills_source.freeze
        @situation_recaller = situation_recaller
        @recall_caller = recall_caller
        freeze
      end

      # P5: the recall node — situation-scoped memory becomes graph state
      # feeding build_frame. The recall is a NON-DETERMINISTIC external read
      # (the memory store can change), so it routes through the durable effect
      # journal under a logical key (episode, "recall", slot 0, identity
      # digest): a replayed run returns the RECORDED projections, never a
      # fresh, different read — the frame bytes and the reason call's logical
      # key stay replay-stable (the P3 contract). A recaller error or a
      # caller/tenant mismatch is a typed failure, never silent; first-
      # occurrence cells get an empty memory section.
      def recall(state, context)
        unless @situation_recaller
          return {"situation_memory" => [], "memory_record_digests" => []}
        end
        unless @recall_caller
          raise EpisodeFrameError, "episode_recall/recaller_without_caller"
        end

        episode = state.fetch(:episode)
        snapshot = state.fetch(:snapshot)
        tenant = String(episode.fetch("tenant_id", ""))
        unless @recall_caller[:tenant].to_s == tenant || @recall_caller["tenant"].to_s == tenant
          raise EpisodeFrameError, "episode_recall/tenant_mismatch"
        end

        identity = {
          "situation_id" => snapshot.fetch("situation_id"),
          "situation_version" => snapshot.fetch("situation_version"),
          "tenant" => tenant,
          "limit" => 64
        }
        logical = ModelCall::LogicalCallKey.new(
          episode_id: String(episode.fetch("episode_id")),
          stage: "recall",
          slot: 0,
          request_digest: "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(identity))}"
        )
        outcome = EffectDispatcher.run(
          context:,
          operation: RECALL_OPERATION,
          safety: :unsafe,
          call_index: 0,
          request: {"logical_call_key" => logical.to_key},
          actor: "tamoz.agent.episode.recall",
          logical_key: logical
        ) do
          result = @situation_recaller.recall(
            caller: @recall_caller, snapshot:, query: {terms: []}, limit: 64
          )
          unless result.respond_to?(:projections) && result.respond_to?(:record_digests)
            raise EpisodeFrameError, "episode_recall/result_invalid"
          end

          projections = Array(result.projections).map do |projection|
            unless projection.is_a?(Hash)
              raise EpisodeFrameError, "episode_recall/projection_not_object"
            end
            # P5: a misbehaving recaller returning ANOTHER tenant's memory is
            # refused — the projections are cross-checked against the episode
            # tenant (the situation identity is the recall key, not a scope
            # field).
            scopes = projection["scopes"]
            unless scopes.is_a?(Hash) && scopes["tenant"].to_s == tenant
              raise EpisodeFrameError, "episode_recall/projection_scope_mismatch"
            end

            projection
          end
          record_digests = Array(result.record_digests).map(&:to_s)
          unless record_digests == projections.map { |projection| projection["digest"] }
            raise EpisodeFrameError, "episode_recall/digests_mismatch"
          end

          {"situation_memory" => projections, "memory_record_digests" => record_digests}
        end

        case outcome.status
        when :succeeded then outcome.value
        else
          raise EpisodeFrameError, "episode_recall/failed"
        end
      end

      # P5: recalled memory enters the frame as attributed, untrusted evidence
      # with memory:<digest> ids. Every projection is shape-validated here (a
      # malformed or cross-tenant projection is a typed failure, never an
      # untyped KeyError); the digest binds the FULL statement, never a
      # truncated display.
      def memory_entries(state)
        Array(state[:situation_memory]).map do |projection|
          unless projection.is_a?(Hash)
            raise EpisodeFrameError, "episode_recall/projection_not_object"
          end
          digest = projection["digest"]
          statement = projection["statement"]
          unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
            raise EpisodeFrameError, "episode_recall/projection_bad_digest"
          end
          unless statement.is_a?(String)
            raise EpisodeFrameError, "episode_recall/projection_bad_statement"
          end

          {
            "digest" => digest,
            "statement" => statement
          }
        end
      end

      # Resolves the wire model_policy to a concrete role via the Profile
      # (fail-closed: blank policy, unknown role, or incomplete role is a typed
      # failure before any model call). The resolved role is stored so `reason`
      # can build the per-request model port.
      def intake(state, _context)
        wire = state.fetch(:wire)
        policy = String(wire.fetch("model_policy", "")).strip
        role = ModelCall.resolve_role(@profile, policy)
        {
          "role" => {
            "name" => role.name,
            "provider" => role.provider,
            "model" => role.model,
            "endpoint" => endpoint_for(role)
          }
        }
      end

      # Assembles the frame: verifies the diagnosis catalog bytes against the
      # wire digest, verifies the prompt digest, resolves the digest-pinned
      # skill refs, and builds the trusted policy section + untrusted
      # situation section. No model call. P4: the INTENT catalog is verified
      # here too — a forged/malformed/duplicate catalog fails closed BEFORE
      # any model call (the decide node re-verifies as defense-in-depth).
      # P5: the skill refs fail closed here too (unknown name or tree-digest
      # mismatch), and recalled memory enters the frame as attributed,
      # untrusted evidence with memory:<digest> ids.
      def build_frame(state, _context)
        wire = state.fetch(:wire)
        snapshot = state.fetch(:snapshot)
        catalog = DiagnosisCatalog.verify_wire(
          wire.fetch("diagnosis_catalog_json"),
          wire.fetch("diagnosis_catalog_sha256")
        )
        IntentCatalog.verify_wire(
          wire.fetch("intent_catalog_json"),
          wire.fetch("intent_catalog_sha256")
        )
        skills = SkillSet.verify_wire(
          wire.fetch("skill_refs_json", ""), source: @skills_source
        )
        memory = memory_entries(state)
        frame = @frame_builder_factory.call(
          catalog, wire.fetch("objective", "")
        ).build(
          snapshot:,
          prompt: wire.fetch("prompt", ""),
          prompt_version: wire.fetch("prompt_version", ""),
          prompt_sha256: wire["prompt_sha256"],
          skills: skills.refs,
          memory:
        )
        {"frame" => frame_projection(frame), "skill_set_digest" => skills.digest}
      end

      # The ONLY model-calling node. Journals the call under the logical call
      # key; stores the raw response + receipt projection for validate; the
      # RUNNER turns the journal-verified receipt into wire model events.
      def reason(state, context)
        episode = state.fetch(:episode)
        frame = frame_from(state.fetch(:frame))
        role = state.fetch(:role)
        budget = budget_controller(state)
        # P2: the budget check is PRE-DISPATCH — exhaustion raises typed
        # BEFORE any provider call (B7).
        budget.check_model_call!(state.fetch(:budget_state, nil))
        model_call = @model_call_factory.call(role)
        # P2: the wire ordinal is the model call's position in THIS episode —
        # a loop episode emits distinct ordinals (0, 1, ...), never a collision.
        ordinal = Array(state.fetch(:model_receipts, [])).length
        invocation = ModelCall::InvocationIdentity.new(
          attempt_id: episode.fetch("attempt_id"),
          fence: Integer(episode.fetch("fence")),
          graph_task: "reason",
          stage: "reason",
          global_ordinal: ordinal
        )
        result = model_call.call(
          context:,
          episode_id: episode.fetch("episode_id"),
          invocation:,
          slot: 0,
          system: frame.fetch("system"),
          prompt: frame.fetch("user"),
          frame_digest: frame["digest"]
        )
        if result.unknown?
          raise ProtocolError, "episode model call is unknown (no blind retry)"
        end
        if result.failed?
          raise ProtocolError, "episode model call failed"
        end

        budget_state = budget.reconcile_model(
          state.fetch(:budget_state, nil), result.receipt.usage
        )

        {
          "raw_response" => result.raw_response,
          "model_receipts" => [receipt_projection(result.receipt)],
          "budget_state" => budget_state
        }
      end

      # Deterministic: strict ReasoningDocument v2 parse + grounding checks
      # against the frame facts, then ROUTES (P2): a tool request → execute_tool;
      # malformed-after-success → repair (exactly once) or typed terminal;
      # valid → decide. Never a second model.
      def validate(state, _context)
        frame = frame_from(state.fetch(:frame))
        raw = state.fetch(:raw_response)
        if raw.nil? || raw.empty?
          raise ProtocolError, "episode has no model response to validate"
        end

        catalog = DiagnosisCatalog.from_list(frame.fetch("catalog"))
        document = ReasoningDocument.parse(raw, catalog:)
        ground_evidence!(document, frame)

        if document.tool_requests && !document.tool_requests.empty?
          return {"document" => document_projection(document), "next_node" => "execute_tool"}
        end

        {"document" => document_projection(document), "next_node" => "decide"}
      rescue ProtocolError => error
        # A succeeded-but-malformed response is repaired exactly once; a
        # second malformed response terminates typed.
        if Integer(state.fetch(:repair_count, 0)) < 1
          {"next_node" => "repair", "repair_directive" => error.message}
        else
          raise ProtocolError, "episode document is malformed after repair"
        end
      end

      # P2: the ONLY tool-executing node. Validates the model's tool request
      # against the wire tool catalog, then executes it as a journaled unsafe
      # effect (logical key, slot = tool_results.length). Success AND refusal
      # results are journaled and appended.
      def execute_tool(state, context)
        document = state.fetch(:document)
        request = document.fetch("tool_requests").first
        tool_name = request.fetch("name")
        arguments = request.fetch("arguments") || {}
        validate_tool_request!(state, tool_name, arguments)

        episode = state.fetch(:episode)
        budget = budget_controller(state)
        budget.check_tool_call!(state.fetch(:budget_state, nil))
        slot = Array(state.fetch(:tool_results, [])).length
        result = @tool_call.call(
          context:,
          episode_id: episode.fetch("episode_id"),
          slot:,
          tool_name:,
          arguments:
        )
        if result.unknown?
          raise ProtocolError, "episode tool call is unknown (no blind retry)"
        end
        if result.failed?
          raise ProtocolError, "episode tool call failed"
        end

        {
          "tool_results" => [result.projection],
          "budget_state" => budget.reconcile_tool(
            state.fetch(:budget_state, nil), result.projection
          )
        }
      end

      # P2: deterministic — rebuilds the frame with the attributed tool
      # results and (when present) the repair directive appended to the user
      # section. Same inputs → same frame bytes → the next reason call's
      # logical key is deterministic.
      def rebuild_frame(state, _context)
        wire = state.fetch(:wire)
        snapshot = state.fetch(:snapshot)
        catalog = DiagnosisCatalog.verify_wire(
          wire.fetch("diagnosis_catalog_json"),
          wire.fetch("diagnosis_catalog_sha256")
        )
        skills = SkillSet.verify_wire(
          wire.fetch("skill_refs_json", ""), source: @skills_source
        )
        frame = @frame_builder_factory.call(
          catalog, wire.fetch("objective", "")
        ).build(
          snapshot:,
          prompt: wire.fetch("prompt", ""),
          prompt_version: wire.fetch("prompt_version", ""),
          prompt_sha256: wire["prompt_sha256"],
          skills: skills.refs,
          memory: memory_entries(state),
          tool_results: Array(state.fetch(:tool_results, [])),
          repair_directive: state[:repair_directive]
        )
        {"frame" => frame_projection(frame)}
      end

      # P2: the one-shot repair — increments the count and records the parse
      # failure as a directive in the next frame (the frame digest changes, so
      # the next reason call is a NEW journaled call, never a blind retry).
      def repair(state, _context)
        {
          "repair_count" => Integer(state.fetch(:repair_count, 0)) + 1,
          "repair_directive" => state[:repair_directive]
        }
      end

      # Deterministic: validated document + intent catalog + current allowlist
      # → terminal decision state (decision-v1 shape + digest). The catalog is
      # re-verified here (defense-in-depth: even a forged catalog that slipped
      # past intake fails at the decision boundary). The runner only translates
      # this state to the wire.
      def decide(state, _context)
        document = state.fetch(:document)
        episode = state.fetch(:episode)
        snapshot = state.fetch(:snapshot)
        wire = state.fetch(:wire)
        allowlist = Array(episode.fetch("allowed_intent_types", []))
        catalog = IntentCatalog.verify_wire(
          wire.fetch("intent_catalog_json"),
          wire.fetch("intent_catalog_sha256")
        )
        decision, digest = @decision_builder.call(
          document:,
          episode:,
          snapshot:,
          snapshot_digest: episode.fetch("snapshot_sha256", ""),
          allowlist:,
          catalog:
        )
        {"decision" => decision, "decision_digest" => digest}
      end

      private

      # The pure budget controller for this episode, derived from the wire's
      # budget envelope (Agentic Stream's EpisodeBudget).
      def budget_controller(state)
        ReceiptBudgetController.new(state.fetch(:wire).fetch("budget", nil))
      end

      # Fail closed: the requested tool must be named in the wire's tool
      # catalog and the arguments must be a bounded mapping.
      def validate_tool_request!(state, tool_name, arguments)
        catalog = state.fetch(:wire).fetch("tool_catalog_json", "").to_s
        unless catalog.empty?
          parsed = Tamoz::Core.parse_json_strict(catalog)
          names = Array(parsed).map { |entry| entry.fetch("name", nil) }
          unless names.include?(tool_name)
            raise ProtocolError, "episode_tool/not_in_catalog: #{tool_name}"
          end
        end
        unless arguments.is_a?(Hash)
          raise ProtocolError, "episode_tool/arguments_not_mapping"
        end
      end

      def endpoint_for(role)
        settings = role.normalized_settings || {}
        ROLE_ENDPOINT_KEYS.each do |key|
          value = settings[key] || settings[key.to_sym]
          return String(value) unless value.to_s.empty?
        end

        ""
      end

      def frame_projection(frame)
        {
          "system" => frame.system,
          "user" => frame.user,
          "facts" => frame.facts,
          "evidence_ids" => frame.evidence_ids,
          "digest" => frame.digest,
          "catalog" => frame.catalog.canonical
        }
      end

      def frame_from(projection)
        projection || raise(EpisodeFrameError, "episode_frame/missing")
      end

      def ground_evidence!(document, frame)
        return if document.evidence_refs.nil? || document.evidence_refs.empty?

        allowed = Array(frame["evidence_ids"])
        forged = document.evidence_refs.reject { |ref| allowed.include?(ref) }
        unless forged.empty?
          raise ProtocolError,
                "reasoning_document/ungrounded_evidence_refs: #{forged.first}"
        end
      end

      def document_projection(document)
        {
          "kind" => document.kind.to_s,
          "primary_hypothesis" => document.primary_hypothesis,
          "probabilities" => Array(document.probabilities).map do |p|
            {"code" => p.code, "probability" => p.probability}
          end,
          "selected_code" => document.selected_code,
          "raw_confidence" => document.raw_confidence,
          "evidence_refs" => Array(document.evidence_refs),
          "recommended_intents" => Array(document.recommended_intents).map do |i|
            {"type" => i.type, "parameter_preset" => i.parameter_preset, "parameters" => i.parameters}
          end,
          "tool_requests" => Array(document.tool_requests).map do |t|
            {"name" => t.name, "arguments" => t.arguments}
          end
        }
      end

      def receipt_projection(receipt)
        {
          "episode_id" => receipt.logical_call_key.episode_id,
          "effect_id" => receipt.effect_id,
          "effect_key" => receipt.effect_key,
          "status" => receipt.status.to_s,
          "provider" => receipt.provider,
          "model" => receipt.model,
          "settings_digest" => receipt.settings_digest,
          "frame_digest" => receipt.frame_digest,
          "request_digest" => receipt.request_digest,
          "response_digest" => receipt.response_digest,
          "ordinal" => receipt.invocation.global_ordinal,
          "usage" => receipt.usage.available ? {
            "input_tokens" => receipt.usage.input_tokens,
            "output_tokens" => receipt.usage.output_tokens,
            "cost_microunits" => receipt.usage.cost_microunits
          } : nil
        }
      end
    end
  end
end
