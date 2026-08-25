# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Binds intake, profile, skill, MCP, and egress data into session records.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList :reek:NilCheck
    # The record schema and optional binding sentinels are the stable wire contract.
    class SessionBindings
      def initialize(configuration:, memory:, graph_version: GraphVersions::GRAPH_VERSION)
        @configuration = configuration
        @memory = memory
        @graph_version = String(graph_version).freeze
      end

      def intake(state, context)
        raw_task = state.fetch(:task)
        return cancellation_update if cancellation_request?(raw_task)

        task = validated_task(raw_task)

        claimed = @memory.claim_behavior_transition(context)
        session_update(task, context, claimed)
      end

      def skill_binding
        {
          skill_epoch: @configuration.toolbox.skill_epoch,
          prompt_surface_digest: @configuration.toolbox.prompt_surface_digest
        }
      end

      def mcp_binding
        source = @configuration.mcp
        return {} if source.nil? || source.catalogs.empty?

        {
          mcp_catalogs: source.mcp_catalogs,
          mcp_source_digests: source.mcp_source_digests
        }
      end

      def egress_binding
        profile = @configuration.profile
        return {} unless profile&.egress

        { egress_pin: Tamoz::Agent::Deliberation.canonical(profile.egress) }
      end

      def profile_binding
        profile = @configuration.profile
        return {} unless profile

        {
          profile_id: profile.profile_id,
          profile_digest: profile.canonical_digest,
          profile_authority: profile.authority_snapshot,
          profile_roles: recorded_profile_roles,
          profile_budgets: recorded_profile_budgets
        }.merge(@configuration.profile_narrowed ? { authority_narrowed: true } : {})
      end

      def recorded_profile_roles
        return @configuration.profile_roles if @configuration.profile_roles
        return {} unless @configuration.profile

        @configuration.profile.model_roles.transform_values do |role|
          { 'provider' => role.fetch('provider'), 'model' => role.fetch('model') }
        end
      end

      def recorded_profile_budgets
        return @configuration.profile_budgets unless @configuration.profile_budgets.nil?
        return {} unless @configuration.profile

        @configuration.profile.budgets
      end

      private

      def cancellation_update
        { next_node: 'terminal', terminal_reason: 'cancelled_by_user' }
      end

      def cancellation_request?(raw_task)
        raw_task.is_a?(Hash) && raw_task['cancel'] == true
      end

      # Channel turns with a transcript nest the text under the task Hash
      # (see CommsStore#admit_and_enqueue); the graph state keeps the text.
      def validated_task(raw_task)
        task = String(raw_task.is_a?(Hash) ? raw_task['text'] : raw_task).strip
        raise ArgumentError, 'task must not be empty' if task.empty?
        if task.bytesize > SessionNodes::MAX_TASK_BYTES
          raise ArgumentError, "task exceeds #{SessionNodes::MAX_TASK_BYTES} bytes"
        end

        task
      end

      def session_update(task, context, claimed)
        toolbox = @configuration.toolbox
        return adaptive_session_update(task, context, claimed, toolbox) if adaptive_graph?

        {
          task:,
          phase: toolbox.action_capable? ? 'discovery' : 'read_only',
          repair_attempt: 0,
          step_cursor: 0,
          next_node: 'deliberate',
          **@memory.claimed_behavior_channel(claimed),
          session: session_record(task, context, claimed, toolbox)
        }
      end

      def adaptive_graph?
        @graph_version == GraphVersions::ADAPTIVE_GRAPH_VERSION
      end

      def adaptive_session_update(task, context, claimed, toolbox)
        {
          task:,
          phase: 'adaptive_read_only',
          repair_attempt: 0,
          step_cursor: 0,
          adaptive_iteration: 0,
          next_node: 'adaptive_decide',
          route: adaptive_route(toolbox),
          **@memory.claimed_behavior_channel(claimed),
          session: session_record(task, context, claimed, toolbox)
        }
      end

      def adaptive_route(toolbox)
        authority_revision = @configuration.profile&.canonical_digest || toolbox.catalog_digest
        catalog_revision = SessionRecords.digest(
          Tamoz::Agent::Deliberation.canonical(@configuration.mcp&.mcp_catalogs || {})
        )
        SessionRecords.build(
          'route',
          route: 'adaptive_read_only',
          reason_class: 'workspace_evidence',
          route_digest: SessionRecords.digest(
            'mode' => 'adaptive_read_only',
            'authority_revision' => authority_revision,
            'catalog_revision' => catalog_revision
          ),
          mode: 'adaptive_read_only',
          authority_revision:,
          catalog_revision:
        )
      end

      def session_record(task, context, claimed, toolbox)
        SessionRecords.build(
          'session',
          session_id: String(context.thread_id),
          task:,
          task_digest: Digest::SHA256.hexdigest(task),
          root: toolbox.root.to_s,
          graph_version: @graph_version,
          behavior_version: @memory.behavior_version(claimed),
          tool_catalog_digest: toolbox.catalog_digest,
          created_at_ms: 0,
          **profile_binding,
          **skill_binding,
          **mcp_binding,
          **egress_binding,
          **@memory.behavior_binding(claimed),
          **@memory.memory_binding
        )
      end
    end
  end
end
