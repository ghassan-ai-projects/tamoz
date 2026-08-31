# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/errors"

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
      MAX_HYPOTHESIS_BYTES = 1_024
      MAX_SUMMARY_BYTES = 4_096
      VALIDITY_WINDOW_SECONDS = 86_400

      def self.build(envelope:, snapshot:, snapshot_digest:, outcome:, catalog:, now: Time.now)
        new(envelope:, snapshot:, snapshot_digest:, outcome:, catalog:, now:).build
      end

      # P6: the RECONSIDER entry — builds the decision-v1 shape + digest over
      # the compensating intents the compensate node produced. One builder,
      # one decision shape (the Go validator enforces the same schema).
      def self.build_decision(intents:, episode:, snapshot:, snapshot_digest:, summary:, now: Time.now)
        with_digest(
          "decision_id" => episode_decision_id(episode),
          "episode_id" => episode.fetch("episode_id"),
          "attempt_id" => episode.fetch("attempt_id"),
          "fence" => episode.fetch("fence"),
          "snapshot_digest" => snapshot_digest,
          "situation_id" => snapshot.fetch("situation_id"),
          "situation_version" => snapshot.fetch("situation_version"),
          "primary_hypothesis" => "",
          "confidence" => 1.0,
          "summary" => String(summary).byteslice(0, MAX_SUMMARY_BYTES),
          "facts_used" => [],
          "alternatives" => [],
          "intents" => intents,
          "valid_until" => (now + VALIDITY_WINDOW_SECONDS).utc.iso8601
        )
      end

      def self.episode_decision_id(episode)
        "decision.#{episode.fetch("episode_id")}." \
          "#{episode.fetch("attempt_id")}.#{episode.fetch("fence")}"
      end

      def self.with_digest(decision)
        [decision, Tamoz::Core.digest(:decision, decision)]
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
        self.class.with_digest(
          "decision_id" => decision_id,
          "episode_id" => @envelope.episode_id,
          "attempt_id" => @envelope.attempt_id,
          "fence" => @envelope.fence,
          "snapshot_digest" => @snapshot_digest,
          "situation_id" => @snapshot.fetch("situation_id"),
          "situation_version" => @snapshot.fetch("situation_version"),
          "primary_hypothesis" => bounded_outcome_text(:primary_hypothesis, MAX_HYPOTHESIS_BYTES),
          "confidence" => confidence,
          "summary" => bounded_outcome_text(:summary, MAX_SUMMARY_BYTES),
          "facts_used" => bounded_outcome_entries(:facts_used, MAX_FACTS),
          "alternatives" => bounded_outcome_entries(:alternatives, MAX_ALTERNATIVES),
          "intents" => intents,
          "valid_until" => valid_until
        )
      end

      private

      def decision_id
        "decision.#{@envelope.episode_id}.#{@envelope.attempt_id}.#{@envelope.fence}"
      end

      def bounded_outcome_text(key, limit)
        String(@outcome.fetch(key, "")).byteslice(0, limit)
      end

      def bounded_outcome_entries(key, limit)
        Array(@outcome.fetch(key, [])).first(limit)
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
      # P6: RECONSIDER episodes are built by the compensate node
      # (build_decision) — this DIAGNOSE-only path never sees them.
      def intents
        proposal = recommended_proposal
        return [watch_condition_intent] if watch_fallback?(proposal)

        entry = admissible_entry(proposal)
        return [watch_condition_intent] unless entry

        # Confidence may cause abstention (watch); it never unlocks an action
        # the catalog or the operator's floor would refuse.
        return [watch_condition_intent] if watch_preferred?

        [actionable_intent(entry, proposal)]
      end

      def watch_fallback?(proposal)
        proposal.nil? || proposal_type(proposal) == Tamoz::Core::INTENT_WATCH_TYPE
      end

      # Catalog-admissible: known to the catalog, on the operator's allowlist,
      # and within the episode's risk ceiling — anything else demotes to the
      # watch observation.
      def admissible_entry(proposal)
        type = proposal_type(proposal)
        return unless @catalog.include?(type) && allowed_intent_types.include?(type)

        entry = @catalog.entry(type)
        return unless risk_within_ceiling?(entry.risk_class)

        entry
      end

      def actionable_intent(entry, proposal)
        build_intent(
          type: entry.type, risk_class: entry.risk_class,
          parameters: build_parameters(entry, proposal),
          evidence_ids: evidence_ids
        )
      end

      # The model's actionable proposal: at most ONE. Two+ actionable intents
      # are a typed refusal (never a silent first-entry truncation).
      def recommended_proposal
        proposals = Array(@outcome.fetch(:recommended_intents, []))
        actionable = proposals.reject { |intent| proposal_type(intent) == Tamoz::Core::INTENT_WATCH_TYPE }
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
        allowed_intent_types.include?(Tamoz::Core::INTENT_WATCH_TYPE)
      end

      def ensure_watch_allowlisted!
        return if watch_allowlisted?

        raise StreamError,
              "no allowed intent for this outcome " \
              "(#{Tamoz::Core::INTENT_WATCH_TYPE} is not in allowed_intent_types)"
      end

      def evidence_ids
        Array(@outcome.fetch(:evidence_ids, []))
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
        parameters = preset_for(entry, proposal)
        apply_episode_bindings!(entry, parameters)
        apply_model_values!(entry, proposal, parameters)
        parameters
      end

      def apply_episode_bindings!(entry, parameters)
        parameters["entity_id"] = @snapshot.fetch("entity").fetch("id")
        if entry.type == Tamoz::Core::INTENT_WATCH_TYPE
          parameters["situation_id"] = @snapshot.fetch("situation_id")
          parameters["situation_version"] = @snapshot.fetch("situation_version")
          apply_watch_bindings!(parameters)
        end
      end

      # The watch condition's target IS the entity — per-episode bound,
      # never operator- or model-authored.
      def apply_watch_bindings!(parameters)
        parameters["target"] = @snapshot.fetch("entity").fetch("id")
        parameters["expires_at"] = valid_until
      end

      def apply_model_values!(entry, proposal, parameters)
        writable = entry.model_writable_fields
        Array(proposal_parameters(proposal)).each do |key, value|
          field = String(key)
          unless writable.include?(field)
            raise StreamError, "intent parameter #{field} is not model-writable for #{entry.type}"
          end

          parameters[field] = value
        end
      end

      def preset_for(entry, proposal)
        requested_preset = proposal_preset(proposal)
        ensure_default_preset!(entry, requested_preset) if requested_preset
        deep_dup(entry.presets.fetch("default", {}))
      end

      def ensure_default_preset!(entry, requested)
        return if requested == "default"

        raise StreamError,
              "only the catalog's default preset is selectable in v1 " \
              "(#{requested} requested for #{entry.type})"
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
        intent_with_digest(intent)
      end

      def intent_with_digest(intent)
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
        ensure_watch_allowlisted!
        entry = @catalog.entry(Tamoz::Core::INTENT_WATCH_TYPE)
        parameters = build_parameters(entry, EmptyProposal.new)
        build_intent(
          type: Tamoz::Core::INTENT_WATCH_TYPE,
          risk_class: entry.risk_class,
          parameters:,
          evidence_ids: evidence_ids
        )
      end

      # A no-op proposal: the watch condition carries NO model values.
      EmptyProposal = Data.define(:type, :parameter_preset, :parameters) do
        def initialize = super(type: nil, parameter_preset: nil, parameters: nil)
      end
    end
  end
end
