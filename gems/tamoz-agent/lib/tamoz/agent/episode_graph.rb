# frozen_string_literal: true

require "tamoz/graph"

module Tamoz
  module Agent
    # P2/§3.1: THE fixed production episode graph — one definition, compiled in
    # process, serving all domains. The reason ↔ tool loop and the one-shot
    # repair are GRAPH BRANCHES bounded by Limits#max_steps, never a Ruby
    # counter:
    #
    #   START → intake → build_frame → reason → validate ─► decide → END
    #                                      ▲                 │ (tool_request)
    #                                      │                 ▼
    #                                      │          execute_tool ─► rebuild_frame
    #                                      │                 │ (malformed, count<1)
    #                                      │                 ▼
    #                                      │                repair ───────►┘
    #                                      └────────────────────────────────┘
    #
    # `reason` is the ONLY model-calling node; `execute_tool` the only
    # tool-calling node — both journaled unsafe effects with logical keys.
    # `validate` parses + routes. `decide` is the deterministic builder as a
    # terminal node. The runner only validates the envelope, delivers to the
    # durable inbox, and translates the terminal state to the wire.
    class EpisodeGraph
      GRAPH_NAME = "tamoz.agent.episode"
      GRAPH_VERSION = "2"

      def self.build(checkpointer:, nodes:)
        Tamoz.graph(name: GRAPH_NAME, version: GRAPH_VERSION) do
          state :episode, default: {}
          state :snapshot, default: {}
          state :wire, default: {}
          state :role, default: nil
          state :frame, default: nil
          state :raw_response, default: nil
          state :model_receipts, reduce: :append, default: []
          state :tool_results, reduce: :append, default: []
          state :repair_count, default: 0
          state :repair_directive, default: nil
          state :budget_state, default: nil
          state :next_node, default: nil
          state :document, default: nil
          state :decision, default: nil
          state :decision_digest, default: nil
          # P5/P6-owned channels, declared so a recall-enabled runner can bind
          # them; P2 keeps them empty/immutable.
          state :situation_memory, default: [], immutable: true
          state :memory_record_digests, default: [], immutable: true
          state :reconsideration, default: nil

          node(:intake, implementation_name: "tamoz.agent.episode.intake", version: "1") do |state, context|
            nodes.intake(state, context)
          end
          node(:build_frame, implementation_name: "tamoz.agent.episode.build_frame", version: "1") do |state, context|
            nodes.build_frame(state, context)
          end
          node(:reason, implementation_name: "tamoz.agent.episode.reason", version: "2") do |state, context|
            nodes.reason(state, context)
          end
          node(:validate, implementation_name: "tamoz.agent.episode.validate", version: "2") do |state, context|
            nodes.validate(state, context)
          end
          node(:execute_tool, implementation_name: "tamoz.agent.episode.execute_tool", version: "1") do |state, context|
            nodes.execute_tool(state, context)
          end
          node(:rebuild_frame, implementation_name: "tamoz.agent.episode.rebuild_frame", version: "1") do |state, context|
            nodes.rebuild_frame(state, context)
          end
          node(:repair, implementation_name: "tamoz.agent.episode.repair", version: "1") do |state, context|
            nodes.repair(state, context)
          end
          node(:decide, implementation_name: "tamoz.agent.episode.decide", version: "1") do |state, context|
            nodes.decide(state, context)
          end

          edge Tamoz::START, :intake
          edge :intake, :build_frame
          edge :build_frame, :reason
          edge :reason, :validate

          # The loop: validate routes — valid → decide; tool request →
          # execute_tool → rebuild_frame → reason; malformed → repair →
          # rebuild_frame → reason. Bounded by Limits#max_steps.
          branch :validate,
                 name: :tamoz_episode_validate_route,
                 version: "1",
                 targets: %i[decide execute_tool repair] do |state|
            state.fetch(:next_node).to_sym
          end

          edge :execute_tool, :rebuild_frame
          edge :rebuild_frame, :reason
          edge :repair, :rebuild_frame
          edge :decide, Tamoz::END
        end.compile(checkpointer: checkpointer)
      end
    end
  end
end
