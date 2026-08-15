# frozen_string_literal: true

require "tamoz/graph"

module Tamoz
  module Agent
    # P1/§3.1: THE fixed production episode graph — one definition, compiled in
    # process, serving all domains. No `--graph FILE` on any production route
    # (the launcher composes this). Orchestration lives in the nodes; the
    # runner only validates the envelope, delivers to the durable inbox, and
    # translates the terminal decision state to the wire.
    #
    #   START → intake → build_frame → reason → validate → decide → END
    #
    # `reason` is the ONLY node that calls a model, and only through
    # EpisodeModelCall/EffectDispatcher. `intake` resolves the model role
    # (fail-closed). `build_frame` verifies catalog + prompt digests. `validate`
    # is deterministic parsing + grounding. `decide` is the deterministic
    # builder as a terminal node: terminal graph state IS the decision.
    class EpisodeGraph
      GRAPH_NAME = "tamoz.agent.episode"
      GRAPH_VERSION = "1"

      def self.build(checkpointer:, nodes:)
        Tamoz.graph(name: GRAPH_NAME, version: GRAPH_VERSION) do
          state :episode, default: {}
          state :snapshot, default: {}
          state :wire, default: {}
          state :role, default: nil
          state :frame, default: nil
          state :raw_response, default: nil
          state :model_receipts, reduce: :append, default: []
          state :document, default: nil
          state :decision, default: nil
          state :decision_digest, default: nil
          # P5/P6-owned channels, declared so a recall-enabled runner can bind
          # them; P1 keeps them empty/immutable.
          state :situation_memory, default: [], immutable: true
          state :memory_record_digests, default: [], immutable: true
          state :reconsideration, default: nil

          node(:intake, implementation_name: "tamoz.agent.episode.intake", version: "1") do |state, context|
            nodes.intake(state, context)
          end
          node(:build_frame, implementation_name: "tamoz.agent.episode.build_frame", version: "1") do |state, context|
            nodes.build_frame(state, context)
          end
          node(:reason, implementation_name: "tamoz.agent.episode.reason", version: "1") do |state, context|
            nodes.reason(state, context)
          end
          node(:validate, implementation_name: "tamoz.agent.episode.validate", version: "1") do |state, context|
            nodes.validate(state, context)
          end
          node(:decide, implementation_name: "tamoz.agent.episode.decide", version: "1") do |state, context|
            nodes.decide(state, context)
          end

          edge Tamoz::START, :intake
          edge :intake, :build_frame
          edge :build_frame, :reason
          edge :reason, :validate
          edge :validate, :decide
          edge :decide, Tamoz::END
        end.compile(checkpointer: checkpointer)
      end
    end
  end
end
