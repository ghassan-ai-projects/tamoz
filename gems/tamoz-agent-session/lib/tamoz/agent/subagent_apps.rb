# frozen_string_literal: true

module Tamoz
  module Agent
    # The compiled child graphs a work session may delegate to, one per role the operator enabled. A child gets the
    # role's tools that the parent may already read with, no memory, transcript or earlier turn, and the subagent
    # surface. None is built unless a plain read runs without asking, so a child never needs an approval.
    class SubagentApps
      GRAPH_NAME = 'tamoz.agent.subagent'

      # One enabled role and its compiled child graph.
      App = Data.define(:role, :app)

      def self.build(options, limits:)
        names = enabled(options)
        return {}.freeze if names.empty? || !reads_allowed?(options)

        roles = Harness::SubagentRoles.shipped
        names.to_h { |name| [name, new(options, roles.fetch(name), limits).app] }.freeze
      end

      def self.enabled(options)
        return [] unless options.routing.to_sym == :work

        harness = options.harness
        Array(harness[:subagents] || harness['subagents']).map(&:to_s).uniq
      end

      def self.reads_allowed?(options)
        engine = options.approval_engine
        request = engine.build_request(tool: 'read_file', argv: [], targets: [], effect_class: :read_only,
                                       session_id: options.approval_session_id,
                                       workspace_root: options.toolbox.root.to_s)
        engine.simulate(request).verdict == :allow
      end

      def initialize(options, role, limits)
        @options = options
        @role = role
        @limits = limits
      end

      def app
        definition = SessionGraph.definition_for(nodes, GraphVersions::WORK_GRAPH_VERSION, name: GRAPH_NAME)
        App.new(role: @role, app: definition.compile(checkpointer: @options.checkpointer, **@limits.call(harness)))
      end

      private

      def nodes
        local = allowed(@options.toolbox.read_only_names)
        arguments = @options.node_arguments(transcript_reader: nil, previous_turn_reader: nil,
                                            allowed_capabilities: local + allowed(Array(@options.mcp&.read_only_names)))
        SessionNodes.new(**arguments, toolbox: toolbox(local), harness:, memory: nil, memory_owner: nil,
                                      child_task_runtime: nil, profile_narrowed: true, subagent_apps: {},
                                      graph_version: GraphVersions::WORK_GRAPH_VERSION)
      end

      def allowed(names) = names.select { |tool| @role.tools.any? { |pattern| Harness::SubagentRole.match?(pattern, tool) } }

      def toolbox(names)
        parent = @options.toolbox
        Tamoz::Tools::Toolbox.new(root: parent.root, allowed_tools: names, skills: parent.skills)
      end

      def harness
        @options.harness.merge(surface: :subagent, persona: Harness::PromptPack.fetch(@role.prompt.delete_suffix('.md')),
                               loop_policy: @role.loop_policy.to_h)
      end
    end
  end
end
