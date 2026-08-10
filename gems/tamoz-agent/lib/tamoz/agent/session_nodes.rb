# frozen_string_literal: true

require "digest"
require "json"

require_relative "session_bindings"
require_relative "session_memory"
require_relative "session_planning_context"
require_relative "session_plan_outcomes"
require_relative "session_plan_attempt"
require_relative "session_effects"
require_relative "session_evidence"
require_relative "session_deliberation"
require_relative "session_steps"
require_relative "session_lifecycle"

module Tamoz
  module Agent
    # The frozen graph-node façade for a durable agent session. Public node names and
    # helper visibility stay stable while each phase is owned by one collaborator.
    class SessionNodes
      MAX_OBSERVATION_BYTES = Runtime::MAX_OBSERVATION_BYTES
      MAX_TASK_BYTES = Runtime::MAX_TASK_BYTES
      GRAPH_VERSION = "1"
      # Rebinding, not a second definition: durable records keep this spelling while
      # the value is owned by `Tamoz::Agent` for the memory layer.
      BEHAVIOR_VERSION = Tamoz::Agent::BEHAVIOR_VERSION

      # Immutable construction inputs shared by the session-node collaborators.
      NodeConfiguration = Data.define(
        :model,
        :toolbox,
        :max_plan_attempts,
        :max_repair_attempts,
        :model_call_safety,
        :profile,
        :mcp,
        :profile_roles,
        :profile_budgets,
        :memory,
        :memory_owner,
        :capabilities
      )

      # Immutable collaborator graph for the durable session façade.
      NodeServices = Data.define(
        :configuration,
        :memory,
        :bindings,
        :planning_context,
        :plan_outcomes,
        :effects,
        :evidence
      )
      private_constant :NodeConfiguration, :NodeServices

      attr_reader :toolbox, :max_plan_attempts, :max_repair_attempts, :model_call_safety,
                  :profile, :mcp, :capabilities

      def initialize(
        model:,
        toolbox:,
        max_plan_attempts:,
        max_repair_attempts:,
        model_call_safety:,
        profile: nil,
        mcp: nil,
        profile_roles: nil,
        profile_budgets: nil,
        memory: nil,
        memory_owner: nil
      )
        @model = model
        @toolbox = toolbox
        @max_plan_attempts = max_plan_attempts
        @max_repair_attempts = max_repair_attempts
        @model_call_safety = model_call_safety
        @profile = profile
        @mcp = mcp
        @memory = memory
        @memory_owner = memory_owner
        @profile_roles = profile_roles
        @profile_budgets = profile_budgets
        verify_profile_roles!(profile_roles)
        @capabilities = CapabilityBinding.build(toolbox:, mcp:)

        configuration = NodeConfiguration.new(
          model:,
          toolbox:,
          max_plan_attempts:,
          max_repair_attempts:,
          model_call_safety:,
          profile:,
          mcp:,
          profile_roles:,
          profile_budgets:,
          memory:,
          memory_owner:,
          capabilities: @capabilities
        )
        @memory_nodes = SessionMemory.new(configuration:)
        @bindings = SessionBindings.new(configuration:, memory: @memory_nodes)
        @planning_context = SessionPlanningContext.new(
          configuration:,
          memory: @memory_nodes
        )
        @plan_outcomes = SessionPlanOutcomes.new(configuration:)
        @effects = SessionEffects.new(configuration:)
        @evidence = SessionEvidence.new(configuration:)
        services = NodeServices.new(
          configuration:,
          memory: @memory_nodes,
          bindings: @bindings,
          planning_context: @planning_context,
          plan_outcomes: @plan_outcomes,
          effects: @effects,
          evidence: @evidence
        )
        @deliberation = SessionDeliberation.new(services:)
        @steps = SessionSteps.new(services:)
        @lifecycle = SessionLifecycle.new(services:)
        freeze
      end

      def intake(state, context) = @bindings.intake(state, context)

      def memory_binding = @memory_nodes.memory_binding

      def claim_behavior_transition(context) = @memory_nodes.claim_behavior_transition(context)

      def claimed_behavior_channel(claimed) = @memory_nodes.claimed_behavior_channel(claimed)

      def behavior_binding(claimed) = @memory_nodes.behavior_binding(claimed)

      def behavior_version(claimed) = @memory_nodes.behavior_version(claimed)

      def skill_binding = @bindings.skill_binding

      def mcp_binding = @bindings.mcp_binding

      def egress_binding = @bindings.egress_binding

      def profile_binding = @bindings.profile_binding

      def recorded_profile_roles = @bindings.recorded_profile_roles

      def recorded_profile_budgets = @bindings.recorded_profile_budgets

      def deliberate(state, context) = @deliberation.deliberate(state, context)

      def step_gate(state, context) = @steps.step_gate(state, context)

      def step_execute(state, context) = @steps.step_execute(state, context)

      def evaluate(state, context) = @lifecycle.evaluate(state, context)

      def verify(state, context) = @lifecycle.verify(state, context)

      def terminal(state, context) = @lifecycle.terminal(state, context)

      private

      def verify_profile_roles!(roles)
        return unless roles

        unless roles.is_a?(Hash)
          raise ProfilePolicyError,
                "profile_roles must be a mapping of role name to {provider, model}"
        end
        roles.each do |name, entry|
          unless entry.is_a?(Hash) && entry.keys.sort == %w[model provider] &&
                 entry["provider"].is_a?(String) && entry["model"].is_a?(String)
            raise ProfilePolicyError,
                  "profile role #{name.inspect} must record exactly string provider and model"
          end
        end
      end
    end
  end
end
