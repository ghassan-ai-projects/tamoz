# frozen_string_literal: true

require "digest"

module Tamoz
  module Stream
    # P14-C (plan §6, design §10) — cognition admission. Every trigger
    # evaluation persists scores/evidence/reasons/completeness/cost/freshness/
    # deadline; the outcome is one of the eight admitted values. The evaluator
    # is PURE (no store, no clock reads beyond the passed `now`), so admission
    # is deterministic and replayable.
    #
    # Supersession (C7/adversarial window): when a NEWER Situation version
    # already admitted cognition, a late evaluation for the OLD version is
    # `superseded` — its snapshot digest is no longer current, so a late
    # Decision dies on the freshness check.
    module CognitionAdmission
      OUTCOMES = %i[ignored debounced coalesced deferred admitted superseded
                    expired rejected].freeze
      BRIDGE_NAMESPACE = "situation"
      REQUEST_ID_DOMAIN = "tamoz.stream.bridge_request.v1\n"

      module_function

      # Evaluate one trigger against the policy.
      #
      # @param trigger [Hash] the persisted trigger evaluation
      #   (scores/evidence/reasons/completeness/cost_estimate/freshness/
      #   deadline/outcome from the operator chain).
      # @param now [Integer] processing time (injected clock).
      # @param debounced_at [Integer, nil] when the same Situation was last
      #   debounced (bounded state).
      # @param last_admitted_at [Integer, nil] when the same Situation last
      #   admitted cognition (cooldown).
      # @param current_version [Integer, nil] the Situation version currently
      #   admitted (supersession guard).
      # @param spec [SituationSpec] the deterministic policy.
      # @return [Symbol] one of OUTCOMES.
      def evaluate(trigger:, now:, debounced_at: nil, last_admitted_at: nil,
                   current_version: nil, spec:)
        situation_version = trigger.fetch("situation_version")

        # Expiry: the deadline passed before evaluation (adversarial window).
        deadline = trigger["deadline"]
        return :expired if deadline && now > deadline

        # Supersession: a newer version already admitted (snapshot no longer
        # current — the late Decision would die on the digest mismatch).
        if current_version && situation_version < current_version
          return :superseded
        end

        # Debounce: the same Situation was debounced within the window.
        if debounced_at && now - debounced_at < spec.debounce_seconds
          return :debounced
        end

        # Cooldown: cognition was admitted within the cooldown window.
        if last_admitted_at && now - last_admitted_at < spec.cooldown_seconds
          return :coalesced
        end

        # Cost bound: the trigger exceeded the spec's cost estimate ceiling.
        return :rejected if trigger.fetch("cost_estimate") > spec.max_cost_estimate

        # Freshness: the evidence is stale for this spec.
        freshness = trigger.fetch("freshness")
        return :ignored if freshness > spec.freshness_seconds

        # Confidence ceiling: the trigger exceeded the spec's risk ceiling.
        score = trigger.fetch("scores").values.max.to_f
        return :rejected if score > spec.max_confidence

        :admitted
      end

      # C7 — the bridge namespace for one Situation: `["situation",
      # situation_id]`. The graph's existing single-fenced-writer-per-namespace
      # rule mechanically enforces "at most one active episode per Situation".
      def bridge_namespace(situation_id)
        [BRIDGE_NAMESPACE, situation_id].freeze
      end

      # The derived bridge request id from tenant + Situation id/version +
      # admission. MUST fit Wire::MAX_REQUEST_ID_BYTES (asserted at build
      # time; oversized -> ConfigurationError, never at enqueue).
      def bridge_request_id(tenant_id:, situation_id:, situation_version:, admission_id:)
        body = [tenant_id, situation_id, situation_version, admission_id]
        "sha256:#{Digest::SHA256.hexdigest(
          REQUEST_ID_DOMAIN + body.join(":")
        )}"
      end
    end
  end
end
