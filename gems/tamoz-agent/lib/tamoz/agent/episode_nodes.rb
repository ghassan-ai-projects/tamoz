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

      def initialize(profile:, frame_builder_factory:, model_call_factory:, decision_builder:)
        @profile = profile
        @frame_builder_factory = frame_builder_factory
        @model_call_factory = model_call_factory
        @decision_builder = decision_builder
        freeze
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
      # wire digest, verifies the prompt digest, and builds the trusted policy
      # section + untrusted situation section. No model call.
      def build_frame(state, _context)
        wire = state.fetch(:wire)
        snapshot = state.fetch(:snapshot)
        catalog = DiagnosisCatalog.verify_wire(
          wire.fetch("diagnosis_catalog_json"),
          wire.fetch("diagnosis_catalog_sha256")
        )
        frame = @frame_builder_factory.call(
          catalog, wire.fetch("objective", "")
        ).build(
          snapshot:,
          prompt: wire.fetch("prompt", ""),
          prompt_version: wire.fetch("prompt_version", ""),
          prompt_sha256: wire["prompt_sha256"]
        )
        {"frame" => frame_projection(frame)}
      end

      # The ONLY model-calling node. Journals the call under the logical call
      # key; stores the raw response + receipt projection for validate; the
      # RUNNER turns the journal-verified receipt into wire model events.
      def reason(state, context)
        episode = state.fetch(:episode)
        frame = frame_from(state.fetch(:frame))
        role = state.fetch(:role)
        model_call = @model_call_factory.call(role)
        invocation = ModelCall::InvocationIdentity.new(
          attempt_id: episode.fetch("attempt_id"),
          fence: Integer(episode.fetch("fence")),
          graph_task: "reason",
          stage: "reason",
          global_ordinal: 0
        )
        result = model_call.call(
          context:,
          episode_id: episode.fetch("episode_id"),
          invocation:,
          slot: 0,
          system: frame.fetch("system"),
          prompt: frame.fetch("user")
        )
        if result.unknown?
          raise ProtocolError, "episode model call is unknown (no blind retry)"
        end
        if result.failed?
          raise ProtocolError, "episode model call failed"
        end

        {
          "raw_response" => result.raw_response,
          "model_receipts" => [receipt_projection(result.receipt)]
        }
      end

      # Deterministic: strict ReasoningDocument v2 parse + grounding checks
      # against the frame facts. Never a second model.
      def validate(state, _context)
        frame = frame_from(state.fetch(:frame))
        raw = state.fetch(:raw_response)
        if raw.nil? || raw.empty?
          raise ProtocolError, "episode has no model response to validate"
        end

        catalog = DiagnosisCatalog.from_list(frame.fetch("catalog"))
        document = ReasoningDocument.parse(raw, catalog:)
        ground_evidence!(document, frame)
        {"document" => document_projection(document)}
      end

      # Deterministic: validated document + current allowlist → terminal
      # decision state (decision-v1 shape + digest). The runner only
      # translates this state to the wire.
      def decide(state, _context)
        document = state.fetch(:document)
        episode = state.fetch(:episode)
        snapshot = state.fetch(:snapshot)
        allowlist = Array(episode.fetch("allowed_intent_types", []))
        decision, digest = @decision_builder.call(
          document:,
          episode:,
          snapshot:,
          snapshot_digest: episode.fetch("snapshot_sha256", ""),
          allowlist:
        )
        {"decision" => decision, "decision_digest" => digest}
      end

      private

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
          "digest" => frame.digest,
          "catalog" => frame.catalog.canonical
        }
      end

      def frame_from(projection)
        projection || raise(EpisodeFrameError, "episode_frame/missing")
      end

      def ground_evidence!(document, frame)
        return if document.evidence_refs.nil? || document.evidence_refs.empty?

        allowed = frame.fetch("facts").map { |entry| "fact:#{entry.fetch("id")}" }
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
