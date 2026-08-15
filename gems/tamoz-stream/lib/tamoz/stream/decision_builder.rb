# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/errors"
require "tamoz/stream/reconsideration"
require "tamoz/agent/intent_catalog"

module Tamoz
  module Stream
    # T2.4 (PLAN_TAMOZ_STREAM_BUILD T2.4) + P4 (PHASE_P4_INTENT_AUTHORITY):
    # the typed Decision, built to the frozen decision-v1 schema and digested
    # with the shared rule (situation-runtime/decision/v1).
    #
    # P4 rebuild: the builder reads EVERY domain fact from the spec-bound
    # IntentCatalog (B9/B10). The model proposes at most one actionable intent
    # (recommended_intents in the validated document); the builder reads the
    # EXACT risk, the parameter schema, the presets, and the model-writable
    # fields from the catalog — the model's own risk claim is never read. No
    # proposal (or an unproposable one) degrades to the R0 watch condition
    # from the catalog. Confidence may cause abstention/watch; it never
    # unlocks authority.
    class DecisionBuilder
      # The risk lattice (R0 < R1 < ... < R4) is the wire enum's semantics,
      # not a domain table.
      RISK_RANK = {
        "R0" => 0, "R1" => 1, "R2" => 2, "R3" => 3, "R4" => 4
      }.freeze
      MAX_FACTS = 64
      MAX_ALTERNATIVES = 16
      MAX_ACTIONABLE_INTENTS = 1
      VALIDITY_WINDOW_SECONDS = 86_400

      def self.build(envelope:, snapshot:, snapshot_digest:, outcome:, catalog:, now: Time.now)
        new(envelope:, snapshot:, snapshot_digest:, outcome:, catalog:, now:).build
      end

      def initialize(envelope:, snapshot:, snapshot_digest:, outcome:, catalog:, now: Time.now)
        @envelope = envelope
        @snapshot = snapshot
        @snapshot_digest = snapshot_digest
        @outcome = outcome
        @catalog = catalog
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
          "valid_until" => valid_until
        }
        digest = Tamoz::Core.digest(:decision, decision)
        [decision, digest]
      end

      private

      def decision_id
        "decision.#{@envelope.episode_id}.#{@envelope.attempt_id}.#{@envelope.fence}"
      end

      def valid_until
        (@now + VALIDITY_WINDOW_SECONDS).utc.iso8601
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
      # allowlist: a ceiling below the catalog-declared risk, or an allowlist
      # without the proposed type, demotes the proposal to the watch
      # observation — never escalates, never substitutes a different action.
      # A RECONSIDER episode proposes the compensating intents from its
      # judgment instead (T6.1), also checked against the catalog (G5).
      def intents
        return reconsideration_intents if @envelope.kind == :reconsider

        diagnose_intents
      end

      # T6.1: the compensating intents the judgment produced. Each is
      # re-validated at the decision boundary — its own verified digest, a
      # risk class within the ceiling, AND a catalog member whose declared
      # risk EQUALS the claimed one — because the graph's outcome is agent
      # output and the worker owns the wire contract. A malformed compensation
      # is a typed failure, never a silent omission that leaves the effect
      # uncompensated behind a PRODUCED terminal.
      #
      # Compensations deliberately bypass the allowed_intent_types allowlist
      # that gates the DIAGNOSE path: the allowlist names the actions a tenant
      # lets the worker PROPOSE; a compensation is the worker's corrective
      # answer to an already-executed effect, and the stream validates it under
      # its own policy pipeline anyway (PROTOCOL §4.2). The CATALOG is not
      # bypassed — a compensation must be a declared catalog member.
      def reconsideration_intents
        compensations = Array(@outcome.fetch(:compensating_intents, []))
                          .first(Reconsideration::MAX_INTENTS)
        invalid = compensations.reject do |intent|
          Reconsideration.valid_compensation?(
            intent, risk_ceiling: @envelope.risk_ceiling
          ) && catalog_member_with_declared_risk?(intent)
        end
        unless invalid.empty?
          raise StreamError,
                "a compensating intent failed the decision boundary " \
                "(bad digest, missing compensates, not a catalog member, " \
                "wrong risk class, or risk above the ceiling)"
        end

        compensations
      end

      def catalog_member_with_declared_risk?(intent)
        type = String(intent.fetch("type", ""))
        @catalog.include?(type) && @catalog.risk_for(type) == String(intent.fetch("risk_class", ""))
      end

      def diagnose_intents
        proposal = recommended_proposal
        return [watch_condition_intent] if proposal.nil? || proposal_type(proposal) == Tamoz::Agent::IntentCatalog::WATCH_TYPE

        type = proposal_type(proposal)
        unless @catalog.include?(type) && allowed_intent_types.include?(type)
          return [watch_condition_intent]
        end

        entry = @catalog.entry(type)
        unless risk_within_ceiling?(entry.risk_class)
          return [watch_condition_intent]
        end

        # Confidence may cause abstention (watch); it never unlocks an action
        # the catalog or the operator's floor would refuse.
        return [watch_condition_intent] if watch_preferred?

        parameters = build_parameters(entry, proposal)
        [
          build_intent(
            type: entry.type, risk_class: entry.risk_class, parameters:,
            evidence_ids: Array(@outcome.fetch(:evidence_ids, []))
          )
        ]
      end

      # The model's actionable proposal: at most ONE. Two+ actionable intents
      # are a typed refusal (never a silent first-entry truncation).
      def recommended_proposal
        proposals = Array(@outcome.fetch(:recommended_intents, []))
        actionable = proposals.reject { |intent| proposal_type(intent) == Tamoz::Agent::IntentCatalog::WATCH_TYPE }
        if actionable.length > MAX_ACTIONABLE_INTENTS
          raise StreamError,
                "a document may propose at most one actionable intent " \
                "(proposed #{actionable.length})"
        end

        actionable.first
      end

      def watch_preferred?
        return true if @outcome.fetch(:watch_only, false)

        floor = @envelope.watch_confidence_floor
        floor > 0.0 && confidence < floor && watch_allowlisted?
      end

      def watch_allowlisted?
        allowed_intent_types.include?(Tamoz::Agent::IntentCatalog::WATCH_TYPE)
      end

      def risk_within_ceiling?(declared_risk)
        RISK_RANK.fetch(declared_risk) <= RISK_RANK.fetch(@envelope.risk_ceiling.to_s.upcase)
      end

      # The parameters are assembled from the catalog's authority ONLY:
      # the operator-authored preset (preferred) + the builder's deterministic
      # per-episode bindings + the model's values for catalog-declared
      # model-writable fields. A model value for any other field is a typed
      # refusal — never silently clamped or dropped.
      def build_parameters(entry, proposal)
        base = preset_for(entry, proposal)
        base["entity_id"] = @snapshot.fetch("entity").fetch("id")
        base["situation_id"] = @snapshot.fetch("situation_id")
        base["situation_version"] = @snapshot.fetch("situation_version")
        if entry.type == Tamoz::Agent::IntentCatalog::WATCH_TYPE
          # The watch condition's target IS the entity — per-episode bound,
          # never operator- or model-authored.
          base["target"] = @snapshot.fetch("entity").fetch("id")
          base["expires_at"] = valid_until
        end

        writable = entry.model_writable_fields
        Array(proposal_parameters(proposal)).each do |key, value|
          field = String(key)
          unless writable.include?(field)
            raise StreamError,
                  "intent parameter #{field} is not model-writable for #{entry.type}"
          end
          base[field] = value
        end
        base
      end

      def preset_for(entry, proposal)
        if proposal_preset(proposal)
          unless proposal_preset(proposal) == "default"
            raise StreamError,
                  "only the catalog's default preset is selectable in v1 " \
                  "(#{proposal_preset(proposal)} requested for #{entry.type})"
          end
          deep_dup(entry.presets.fetch("default", {}))
        else
          deep_dup(entry.presets.fetch("default", {}))
        end
      end

      # The proposal arrives as the document projection (plain hashes) or, in
      # direct builder tests, as ReasoningDocument::RecommendedIntent objects —
      # read both shapes.
      def proposal_type(proposal)
        proposal.is_a?(Hash) ? proposal["type"] : proposal.type
      end

      def proposal_preset(proposal)
        proposal.is_a?(Hash) ? proposal["parameter_preset"] : proposal.parameter_preset
      end

      def proposal_parameters(proposal)
        proposal.is_a?(Hash) ? proposal["parameters"] : proposal.parameters
      end

      def deep_dup(value)
        case value
        when Hash then value.to_h { |key, entry| [key, deep_dup(entry)] }
        when Array then value.map { |entry| deep_dup(entry) }
        else value
        end
      end

      def allowed_intent_types
        allowed = @envelope.wire.allowed_intent_types.to_a
        if allowed.empty?
          raise StreamError,
                "allowed_intent_types must not be empty (fail closed)"
        end

        allowed
      end

      # The consequential intent uses the risk class DECLARED in the catalog —
      # the model's claim is never read (B10).
      def build_intent(type:, risk_class:, parameters:, evidence_ids:)
        intent = {
          "intent_id" => "intent.#{@envelope.episode_id}.#{@envelope.attempt_id}.#{@envelope.fence}.#{type}",
          "decision_id" => decision_id,
          "tenant_id" => @envelope.tenant_id,
          "situation_id" => @snapshot.fetch("situation_id"),
          "situation_version" => @snapshot.fetch("situation_version"),
          "type" => type,
          "risk_class" => risk_class,
          "parameters" => parameters,
          "evidence_ids" => evidence_ids,
          "expires_at" => valid_until
        }
        # The intent digest covers the intent WITHOUT its own digest.
        intent.merge("intent_digest" => Tamoz::Core.digest(
          :intent, intent.reject { |key, _| key == "intent_digest" }
        ))
      end

      # The observation intent (R0, from the catalog) for an uncertain
      # episode: install a CEL watch condition on the situation, never touch
      # the entity. Its parameters come from the catalog's watch preset + the
      # per-episode bindings. The watch type must be allowlisted — a decision
      # carrying an unallowlisted watch would be rejected by Agentic Stream,
      # so an episode whose allowlist leaves NO valid intent for the outcome
      # fails closed here, typed, instead of producing an invalid decision.
      def watch_condition_intent
        unless watch_allowlisted?
          raise StreamError,
                "no allowed intent for this outcome " \
                "(install_watch_condition is not in allowed_intent_types)"
        end

        entry = @catalog.entry(Tamoz::Agent::IntentCatalog::WATCH_TYPE)
        parameters = build_parameters(entry, EmptyProposal.new)
        build_intent(
          type: Tamoz::Agent::IntentCatalog::WATCH_TYPE,
          risk_class: entry.risk_class,
          parameters:,
          evidence_ids: Array(@outcome.fetch(:evidence_ids, []))
        )
      end

      # A no-op proposal: the watch condition carries NO model values.
      EmptyProposal = Struct.new(:type, :parameter_preset, :parameters) do
        def initialize = super(nil, nil, nil)
      end
    end
  end
end
