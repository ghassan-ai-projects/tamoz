# frozen_string_literal: true

require "tamoz/stream/decision_builder"

module Tamoz
  module Stream
    # P1/§3.1: the decide-node port (injected into the fixed episode graph at
    # the worker composition). The deterministic decision builder stays in
    # tamoz-stream — it owns the frozen decision-v1 schema and the
    # catalog-driven intent logic (P4: every domain fact comes from the
    # spec-bound IntentCatalog; the model proposes, the catalog declares the
    # authority). The node passes the validated document projection, the
    # verified catalog, and the episode view; the builder returns the
    # [decision, digest] pair the terminal graph state carries. The runner
    # only translates that state to the wire.
    class DecisionNodeBuilder
      def call(document:, episode:, snapshot:, snapshot_digest:, allowlist:, catalog:)
        outcome = {
          primary_hypothesis: String(document.fetch("primary_hypothesis", "")),
          confidence: document.fetch("raw_confidence", 0.0),
          summary: "selected #{document.fetch("selected_code", "unknown")} " \
                   "at confidence #{document.fetch("raw_confidence", 0.0)}",
          facts_used: Array(document.fetch("evidence_refs")).map { |ref| {"evidence" => ref} },
          alternatives: [],
          recommended_intents: Array(document.fetch("recommended_intents", [])),
          evidence_ids: Array(document.fetch("evidence_refs"))
        }
        DecisionBuilder.build(
          envelope: EnvelopeView.new(episode:, allowlist:),
          snapshot:,
          snapshot_digest:,
          outcome:,
          catalog:
        )
      end

      # The minimal envelope view the DecisionBuilder reads — the episode
      # payload hash is the durable source; no wire object is reconstructed.
      EnvelopeView = Struct.new(:episode, :allowlist) do
        def episode_id = episode.fetch("episode_id")
        def attempt_id = episode.fetch("attempt_id")
        def fence = episode.fetch("fence")
        def tenant_id = episode.fetch("tenant_id")
        def situation_id = episode.fetch("situation_id")
        def situation_version = episode.fetch("situation_version")
        def risk_ceiling = episode.fetch("risk_ceiling")
        def kind = episode.fetch("kind").to_sym
        def watch_confidence_floor = episode.fetch("watch_confidence_floor", 0.5)
        def wire = self
        def allowed_intent_types = allowlist
      end
      private_constant :EnvelopeView
    end
  end
end
