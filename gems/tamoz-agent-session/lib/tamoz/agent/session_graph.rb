# frozen_string_literal: true

module Tamoz
  module Agent
    # The per-variant declaration of the session graph — one home for the DSL
    # assembly. Variants: v1 (no compactions channel), routed (the CURRENT
    # graph adds the route node), adaptive (adds the adaptive loop), and
    # compaction. Declaration helpers take the graph Builder as their first
    # argument; every node call site names its node method explicitly.
    module SessionGraph
      GRAPH_NAME = 'tamoz.agent.session'

      module_function

      def definition_for(nodes, version)
        version = String(version)
        Tamoz.graph(name: GRAPH_NAME, version: version) do
          SessionGraph.declare_states(self, version)
          SessionGraph.declare_nodes(self, nodes, version)
          SessionGraph.declare_edges(self, version)
          SessionGraph.declare_branches(self, version)
        end
      end

      def declare_states(builder, version)
        StateDeclaration.declare(builder, version)
      end

      def declare_nodes(builder, nodes, version)
        node_on(builder, :intake) { |state, context| nodes.intake(state, context) }
        return work_nodes(builder, nodes) if work?(version)

        node_on(builder, :route) { |state, context| nodes.route(state, context) } if routed?(version)
        adaptive_nodes(builder, nodes) if adaptive?(version)
        deliberation_nodes(builder, nodes)
      end

      def adaptive_nodes(builder, nodes)
        node_on(builder, :adaptive_decide) { |state, context| nodes.adaptive_decide(state, context) }
        node_on(builder, :adaptive_validate) { |state, context| nodes.adaptive_validate(state, context) }
        node_on(builder, :adaptive_dispatch) { |state, context| nodes.adaptive_dispatch(state, context) }
        node_on(builder, :adaptive_observe) { |state, context| nodes.adaptive_observe(state, context) }
      end

      def work_nodes(builder, nodes)
        node_on(builder, :work_step) { |state, context| nodes.work_step(state, context) }
        node_on(builder, :work_gate) { |state, context| nodes.work_gate(state, context) }
        node_on(builder, :work_execute) { |state, context| nodes.work_execute(state, context) }
        node_on(builder, :work_observe) { |state, context| nodes.work_observe(state, context) }
        node_on(builder, :terminal) { |state, context| nodes.terminal(state, context) }
      end

      def deliberation_nodes(builder, nodes)
        node_on(builder, :deliberate) { |state, context| nodes.deliberate(state, context) }
        node_on(builder, :step_gate) { |state, context| nodes.step_gate(state, context) }
        node_on(builder, :step_execute) { |state, context| nodes.step_execute(state, context) }
        node_on(builder, :evaluate) { |state, context| nodes.evaluate(state, context) }
        node_on(builder, :verify) { |state, context| nodes.verify(state, context) }
        node_on(builder, :terminal) { |state, context| nodes.terminal(state, context) }
      end

      def declare_edges(builder, version)
        builder.edge Tamoz::START, :intake
        builder.edge :intake, successor(version) unless work?(version)
        builder.edge :verify, :terminal unless work?(version)
        builder.edge :terminal, Tamoz::END
      end

      def declare_branches(builder, version)
        return work_branches(builder) if work?(version)

        next_node_branch(builder, :route, :route_route, %i[step_gate deliberate terminal]) if routed?(version)
        next_node_branch(builder, :deliberate, :deliberate_route, %i[step_gate verify terminal])
        next_node_branch(builder, :step_gate, :step_gate_route, %i[step_execute evaluate terminal])
        next_node_branch(builder, :step_execute, :step_execute_route, %i[evaluate terminal])
        next_node_branch(builder, :evaluate, :evaluate_route, %i[step_gate deliberate verify])
        return unless adaptive?(version)

        next_node_branch(builder, :adaptive_decide, :adaptive_decide_route,
                         %i[adaptive_validate terminal deliberate])
        next_node_branch(builder, :adaptive_validate, :adaptive_validate_route,
                         %i[adaptive_dispatch terminal deliberate])
        next_node_branch(builder, :adaptive_dispatch, :adaptive_dispatch_route,
                         %i[adaptive_observe terminal])
        next_node_branch(builder, :adaptive_observe, :adaptive_observe_route,
                         %i[adaptive_decide terminal])
      end

      def work_branches(builder)
        next_node_branch(builder, :intake, :intake_route, %i[work_step terminal])
        next_node_branch(builder, :work_step, :work_step_route, %i[work_gate work_observe terminal])
        next_node_branch(builder, :work_gate, :work_gate_route,
                         %i[work_gate work_execute work_observe work_step terminal])
        next_node_branch(builder, :work_execute, :work_execute_route, %i[work_gate terminal])
        next_node_branch(builder, :work_observe, :work_observe_route, %i[work_step terminal])
      end

      # Every session branch routes the same way — on the next_node channel —
      # so the router is one shared command, not eight copies.
      def next_node_branch(builder, source, name, targets)
        builder.branch(source, name:, version: '1', targets:) do |state|
          state.fetch(:next_node).to_sym
        end
      end

      def node_on(builder, name, &)
        builder.node(name, implementation_name: "tamoz.agent.session.#{name}", version: '1', &)
      end

      def successor(version)
        if adaptive?(version)
          :adaptive_decide
        elsif routed?(version)
          :route
        else
          :deliberate
        end
      end

      def routed?(version)
        version == GraphVersions::CURRENT_GRAPH_VERSION
      end

      def adaptive?(version)
        version == GraphVersions::ADAPTIVE_GRAPH_VERSION
      end

      def work?(version)
        version == GraphVersions::WORK_GRAPH_VERSION
      end

      # The state channels as literal lists (the codebase's data-list pattern,
      # cf. StreamPartContract), so the declaration stays declarative.
      module StateDeclaration
        APPEND_CHANNELS = %i[
          plan_versions plan_reviews approvals effect_intents effect_receipts
          context_controls observations seen_action_signatures
          seen_failure_signatures behavior_transition_claim
        ].freeze
        ADAPTIVE_APPEND_CHANNELS = %i[adaptive_decisions adaptive_seen_actions].freeze

        module_function

        def declare(builder, version)
          scalar_channels(builder)
          APPEND_CHANNELS.each { |name| builder.state name, reduce: :append, default: [] }
          variant_channels(builder, version)
        end

        def scalar_channels(builder)
          builder.state :task, default: ''
          builder.state :phase, default: ''
          builder.state :next_node, default: 'intake'
          builder.state :terminal_reason, default: 'no_check'
          builder.state :repair_attempt, default: 0
          builder.state :step_cursor, default: 0
          builder.state :provider_ambiguity, default: 0
          builder.state :check_passed, default: false
          builder.state :session
          builder.state :accepted_plan
          builder.state :verification
          builder.state :blocked
          builder.state :terminal
        end

        WORK_APPEND_CHANNELS = %i[work_entries work_signatures work_trace].freeze
        WORK_SCALAR_CHANNELS = {
          work_pending: nil, work_cursor: 0, work_prepared: nil, work_plan: nil, work_plan_reviews: 0,
          work_step_count: 0, work_series: nil, work_compactions: 0, work_resets: 0, work_mutated: false,
          work_verified: false, work_checked: false, work_boundary: false, work_overflowed: false,
          work_force_reduce: false, work_exhausted: nil, work_started_ms: 0, work_mutation_count: 0,
          work_turn: nil, work_reminders: []
        }.freeze

        def work_channels(builder)
          WORK_APPEND_CHANNELS.each { |name| builder.state name, reduce: :append, default: [] }
          WORK_SCALAR_CHANNELS.each { |name, default| builder.state name, default: }
        end

        def variant_channels(builder, version)
          work_channels(builder) if SessionGraph.work?(version)
          builder.state :route if SessionGraph.routed?(version) || SessionGraph.adaptive?(version)
          add_compactions_channel(builder, version) unless version == GraphVersions::GRAPH_VERSION
          return unless SessionGraph.adaptive?(version)

          builder.state :adaptive_iteration, default: 0
          builder.state :adaptive_action
          builder.state :adaptive_pending_observation
          builder.state :adaptive_terminal_detail, default: nil
          builder.state :lifecycle_events, reduce: :append, default: []
          ADAPTIVE_APPEND_CHANNELS.each { |name| builder.state name, reduce: :append, default: [] }
        end

        def add_compactions_channel(builder, _version)
          builder.state :compactions, reduce: :append, default: []
        end
      end
    end
  end
end
