# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Stream
    # T2.4 (PLAN_TAMOZ_STREAM_BUILD T2.4): the typed Decision, built to the
    # frozen decision-v1 schema and digested with the shared rule
    # (situation-runtime/decision/v1). At low confidence a watch condition
    # (R0, CEL-compilable expression) is preferred over a consequential action
    # (R2) — the episode proposes observation, not intervention, when it is
    # not sure.
    class DecisionBuilder
      # Below this confidence the builder proposes install_watch_condition.
      CONFIDENCE_WATCH_FLOOR = 0.5

      def self.build(envelope:, snapshot:, snapshot_digest:, outcome:, now: Time.now)
        new(envelope:, snapshot:, snapshot_digest:, outcome:, now:).build
      end

      def initialize(envelope:, snapshot:, snapshot_digest:, outcome:, now: Time.now)
        @envelope = envelope
        @snapshot = snapshot
        @snapshot_digest = snapshot_digest
        @outcome = outcome
        @now = now
      end

      # Returns [decision_hash, decision_digest]. The digest covers the whole
      # decision document (CONTRACTS §3.2, decision domain).
      def build
        decision = {
          "decision_id" => decision_id,
          "episode_id" => @envelope.episode_id,
          "attempt_id" => @envelope.attempt_id,
          "fence" => @envelope.fence,
          "snapshot_digest" => @snapshot_digest,
          "situation_id" => @snapshot.fetch("situation_id"),
          "situation_version" => @snapshot.fetch("situation_version"),
          "primary_hypothesis" => String(@outcome.fetch(:primary_hypothesis, "")).byteslice(0, 1024),
          "confidence" => confidence,
          "summary" => String(@outcome.fetch(:summary, "")).byteslice(0, 4096),
          "facts_used" => Array(@outcome.fetch(:facts_used, [])),
          "alternatives" => Array(@outcome.fetch(:alternatives, [])),
          "intents" => intents,
          "valid_until" => @now.utc.iso8601
        }
        digest = Tamoz::Core.digest(:decision, decision)
        [decision, digest]
      end

      private

      def decision_id
        "decision.#{@envelope.episode_id}.#{@envelope.attempt_id}.#{@envelope.fence}"
      end

      def confidence
        value = @outcome.fetch(:confidence, 0.0)
        value.is_a?(Numeric) ? [[value.to_f, 0.0].max, 1.0].min : 0.0
      end

      def intents
        return [watch_condition_intent] if confidence < CONFIDENCE_WATCH_FLOOR

        [action_intent]
      end

      # The consequential intent (R2) for a confident episode.
      def action_intent
        build_intent(
          type: "maintenance.ticket",
          risk_class: "R2",
          parameters: {
            "entity_id" => @snapshot.fetch("entity").fetch("id"),
            "hypothesis" => String(@outcome.fetch(:primary_hypothesis, "")).byteslice(0, 512)
          }
        )
      end

      # The observation intent (R0) for an uncertain episode: install a CEL
      # watch condition on the situation, never touch the entity.
      def watch_condition_intent
        metric = String(@outcome.fetch(:watch_metric, "condition_score"))
        threshold = @outcome.fetch(:watch_threshold, 0.8)
        build_intent(
          type: "install_watch_condition",
          risk_class: "R0",
          parameters: {
            "expression" => "situation.#{metric} >= #{threshold}",
            "metric" => metric,
            "threshold" => threshold,
            "entity_id" => @snapshot.fetch("entity").fetch("id")
          }
        )
      end

      def build_intent(type:, risk_class:, parameters:)
        intent = {
          "intent_id" => "intent.#{@envelope.episode_id}.#{@envelope.attempt_id}.#{@envelope.fence}.#{type}",
          "decision_id" => decision_id,
          "tenant_id" => @envelope.tenant_id,
          "situation_id" => @snapshot.fetch("situation_id"),
          "situation_version" => @snapshot.fetch("situation_version"),
          "type" => type,
          "risk_class" => risk_class,
          "parameters" => parameters,
          "expires_at" => (@now + 86_400).utc.iso8601
        }
        # The intent digest covers the intent WITHOUT its own digest.
        intent.merge("intent_digest" => Tamoz::Core.digest(
          :intent, intent.reject { |key, _| key == "intent_digest" }
        ))
      end
    end
  end
end
