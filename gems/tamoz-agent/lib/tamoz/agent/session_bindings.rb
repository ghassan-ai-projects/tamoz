# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Binds intake, profile, skill, MCP, and egress data into session records.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList :reek:NilCheck
    # The record schema and optional binding sentinels are the stable wire contract.
    class SessionBindings
      def initialize(configuration:, memory:)
        @configuration = configuration
        @memory = memory
      end

      def intake(state, context)
        raw_task = state.fetch(:task)
        return cancellation_update if raw_task.is_a?(Hash) && raw_task['cancel'] == true

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
        return {} unless source && !source.catalogs.empty?

        { mcp_catalogs: source.mcp_catalogs }
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
        }
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

      def validated_task(raw_task)
        task = String(raw_task).strip
        raise ArgumentError, 'task must not be empty' if task.empty?
        if task.bytesize > SessionNodes::MAX_TASK_BYTES
          raise ArgumentError, "task exceeds #{SessionNodes::MAX_TASK_BYTES} bytes"
        end

        task
      end

      def session_update(task, context, claimed)
        toolbox = @configuration.toolbox
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

      def session_record(task, context, claimed, toolbox)
        SessionRecords.build(
          'session',
          session_id: String(context.thread_id),
          task:,
          task_digest: Digest::SHA256.hexdigest(task),
          root: toolbox.root.to_s,
          graph_version: SessionNodes::GRAPH_VERSION,
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
