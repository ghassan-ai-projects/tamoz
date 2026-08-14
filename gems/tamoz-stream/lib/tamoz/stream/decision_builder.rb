# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/errors"
require "tamoz/stream/reconsideration"

module Tamoz
  module Stream
    # T2.4 (PLAN_TAMOZ_STREAM_BUILD T2.4): the typed Decision, built to the
    # frozen decision-v1 schema and digested with the shared rule
    # (situation-runtime/decision/v1). The builder selects the safest
    # expressible action from the wire allowlist and falls back to a watch
    # condition when no action can be expressed.
    class DecisionBuilder
      RISK_ORDER = {
        "r0" => 0, "r1" => 1, "r2" => 2, "r3" => 3, "r4" => 4
      }.freeze
      ACTION_RISKS = {
        "create_maintenance_ticket" => "r1",
        "recommend_operating_limit" => "r2",
        "dispatch_crew" => "r2",
        "isolate_segment" => "r3",
        "start_aerator" => "r1",
        "halt_feeding" => "r1",
        "emergency_water_exchange" => "r2",
        "downgrade_intervention" => "r1",
        "withdraw_intervention" => "r1"
      }.freeze
      HIGH_CONFIDENCE = 0.85
      MAX_FACTS = 64
      MAX_ALTERNATIVES = 16
      VALIDITY_WINDOW_SECONDS = 86_400

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
          "facts_used" => Array(@outcome.fetch(:facts_used, [])).first(MAX_FACTS),
          "alternatives" => Array(@outcome.fetch(:alternatives, [])).first(MAX_ALTERNATIVES),
          "intents" => intents,
          "valid_until" => (@now + VALIDITY_WINDOW_SECONDS).utc.iso8601
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
        if value.is_a?(Numeric) && value.finite?
          [[value.to_f, 0.0].max, 1.0].min
        else
          0.0
        end
      end

      # The intent set respects the episode's own risk ceiling and intent
      # allowlist (T1.3): a ceiling below the action's risk class, or an
      # allowlist without the action type, demotes the proposal to an
      # observation — never escalates. A RECONSIDER episode proposes the
      # compensating intents from its judgment instead (T6.1).
      def intents
        return reconsideration_intents if @envelope.kind == :reconsider

        diagnose_intents
      end

      # T6.1: the compensating intents the judgment produced. Each is
      # re-validated at the decision boundary — its own verified digest and a
      # risk class within the ceiling — because the graph's outcome is agent
      # output and the worker owns the wire contract. A malformed compensation
      # is a typed failure, never a silent omission that leaves the effect
      # uncompensated behind a PRODUCED terminal.
      #
      # Compensations deliberately bypass the allowed_intent_types allowlist
      # that gates the DIAGNOSE path: the allowlist names the actions a tenant
      # lets the worker PROPOSE; a compensation is the worker's corrective
      # answer to an already-executed effect, and the stream validates it under
      # its own policy pipeline anyway (PROTOCOL §4.2).
      def reconsideration_intents
        compensations = Array(@outcome.fetch(:compensating_intents, []))
                          .first(Reconsideration::MAX_INTENTS)
        invalid = compensations.reject do |intent|
          Reconsideration.valid_compensation?(
            intent, risk_ceiling: @envelope.risk_ceiling
          )
        end
        unless invalid.empty?
          raise StreamError,
                "a compensating intent failed the decision boundary " \
                "(bad digest, missing compensates, wrong risk class, " \
                "or risk above the ceiling)"
        end

        compensations
      end

      def diagnose_intents
        if watch_preferred?
          intents = [watch_condition_intent]
          type = expressible_action_type(risk_class: "r1")
          intents << action_intent(type:) if type
          return intents
        end

        if confidence >= HIGH_CONFIDENCE
          types = expressible_action_types(limit: 2)
          return types.map { |type| action_intent(type:) } unless types.empty?
        else
          type = expressible_action_type
          return [action_intent(type:)] if type
        end

        [watch_condition_intent]
      end

      def watch_preferred?
        floor = @envelope.watch_confidence_floor
        floor > 0.0 && confidence < floor && watch_allowlisted?
      end

      def watch_allowlisted?
        allowed_intent_types.include?("install_watch_condition")
      end

      def expressible_action_type(highest_risk: false, risk_class: nil)
        candidate = select_action_candidate(
          expressible_action_candidates(risk_class:), highest_risk:
        )
        candidate&.first
      end

      def expressible_action_types(limit:)
        expressible_action_candidates.sort_by do |_type, candidate_risk|
          -RISK_ORDER.fetch(candidate_risk)
        end.first(limit).map(&:first)
      end

      def expressible_action_candidates(risk_class: nil)
        allowed_intent_types.filter_map do |type|
          candidate_risk = ACTION_RISKS[type]
          next unless candidate_risk
          next unless expressible_candidate?(candidate_risk, risk_class)

          [type, candidate_risk]
        end
      end

      def expressible_candidate?(candidate_risk, required_risk)
        return false if required_risk && candidate_risk != required_risk

        RISK_ORDER.fetch(candidate_risk) <= RISK_ORDER.fetch(@envelope.risk_ceiling)
      end

      def select_action_candidate(candidates, highest_risk:)
        if highest_risk
          candidates.max_by { |_type, candidate_risk| RISK_ORDER.fetch(candidate_risk) }
        else
          candidates.min_by { |_type, candidate_risk| RISK_ORDER.fetch(candidate_risk) }
        end
      end

      def allowed_intent_types
        allowed = @envelope.wire.allowed_intent_types.to_a
        allowed.empty? ? ACTION_RISKS.keys : allowed
      end

      # The consequential intent uses the risk class declared for its wire
      # type, rather than the builder's former fixed R2 vocabulary.
      def action_intent(type:)
        build_intent(
          type:, risk_class: ACTION_RISKS.fetch(type).upcase,
          parameters: {
            "entity_id" => @snapshot.fetch("entity").fetch("id"),
            "hypothesis" => String(@outcome.fetch(:primary_hypothesis, "")).byteslice(0, 512)
          }
        )
      end

      # The observation intent (R0) for an uncertain episode: install a CEL
      # watch condition on the situation, never touch the entity.
      def watch_condition_intent
        metric = String(@outcome.fetch(:watch_metric, "condition_score")).byteslice(0, 128)
        threshold = @outcome.fetch(:watch_threshold, 0.8)
        build_intent(
          type: "install_watch_condition",
          risk_class: "R0",
          parameters: {
            "expression" => "situation.#{metric} >= #{threshold}",
            "metric" => metric,
            "threshold" => threshold,
            "entity_id" => @snapshot.fetch("entity").fetch("id"),
            "target" => @snapshot.fetch("entity").fetch("id"),
            "expires_at" => (@now + VALIDITY_WINDOW_SECONDS).utc.iso8601,
            "situation_id" => @snapshot.fetch("situation_id"),
            "situation_version" => @snapshot.fetch("situation_version"),
            "max_fires" => 3
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
          "expires_at" => (@now + VALIDITY_WINDOW_SECONDS).utc.iso8601
        }
        # The intent digest covers the intent WITHOUT its own digest.
        intent.merge("intent_digest" => Tamoz::Core.digest(
          :intent, intent.reject { |key, _| key == "intent_digest" }
        ))
      end
    end
  end
end
