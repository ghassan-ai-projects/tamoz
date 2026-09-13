# frozen_string_literal: true

module Tamoz
  module Agent
    class Session
      # The duck-typed MCP source surface (P10 §3): verified at construction,
      # so a half-wired source fails before any graph exists.
      MCP_SOURCE_METHODS = %i[
        mcp_catalogs catalogs names read_only_names name? read_only?
        maximum_effect_output_bytes validate effect_intent
        preview execute descriptors descriptor_for
      ].freeze

      # Every member that is not required — `Data.new` then fails only when
      # the caller omits model, toolbox, or checkpointer.
      OPTIONS_DEFAULTS = {
        max_plan_attempts: 3,
        max_repair_attempts: SessionNodes::MAX_REPAIR_ATTEMPTS,
        approval_engine: nil,
        approval_session_id: nil,
        model_call_safety: :idempotent,
        profile: nil,
        mcp: nil,
        profile_roles: nil,
        profile_budgets: nil,
        profile_narrowed: false,
        memory: nil,
        memory_owner: nil,
        artifact_store: nil,
        artifact_tenant: nil,
        child_task_runtime: nil,
        routing: :legacy
      }.freeze

      # The frozen construction options for a Session — every keyword, its
      # default, and its validation in one place. `Options.build` is the only
      # construction path: it defaults, normalizes, and fails closed before
      # any graph is compiled.
      Options = Data.define(
        :model, :toolbox, :checkpointer, :max_plan_attempts, :max_repair_attempts,
        :approval_engine, :approval_session_id, :model_call_safety,
        :profile, :mcp, :profile_roles, :profile_budgets, :profile_narrowed,
        :memory, :memory_owner, :artifact_store, :artifact_tenant,
        :child_task_runtime, :routing
      ) do
        # Pipeline A: every durable session has exactly one policy owner. A
        # caller that supplies none gets the driver's bundled default (the
        # implement profile over memory stores) — gating is never skipped,
        # only defaulted; a bare consumer of this gem fails loudly instead.
        def self.build(**arguments)
          normalized = arguments.merge(
            profile_narrowed: arguments.fetch(:profile_narrowed, false) == true,
            approval_engine: arguments.fetch(:approval_engine, nil) ||
                               SessionApprovalWiring.default_engine
          )
          new(**OPTIONS_DEFAULTS, **normalized).tap(&:validate)
        end

        def default_graph_version
          GRAPH_VERSION_BY_ROUTING.fetch(routing.to_sym)
        end

        def node_arguments(transcript_reader:)
          {
            model:, toolbox:, max_plan_attempts:, max_repair_attempts:,
            approval_engine:, approval_session_id:, model_call_safety:,
            profile:, mcp:, profile_roles:, profile_budgets:, profile_narrowed:,
            memory:, memory_owner:, artifact_store:, artifact_tenant:,
            child_task_runtime:, transcript_reader:
          }
        end

        def validate
          validate_model!
          validate_limits!
          validate_safety!
          validate_routing!
          validate_checkpointer!
          validate_mcp_source!
          verify_profile_binding!
        end

        private

        def validate_model!
          return if model.respond_to?(:generate)

          raise ArgumentError, 'model must respond to generate'
        end

        def validate_limits!
          validate_plan_limit!
          validate_repair_limit!
        end

        def validate_plan_limit!
          return if max_plan_attempts.is_a?(Integer) && max_plan_attempts.between?(1, 10)

          raise ArgumentError, 'max_plan_attempts must be between 1 and 10'
        end

        def validate_repair_limit!
          return if max_repair_attempts.is_a?(Integer) && max_repair_attempts.between?(0, 10)

          raise ArgumentError, 'max_repair_attempts must be between 0 and 10'
        end

        def validate_safety!
          return if MODEL_CALL_SAFETIES.include?(model_call_safety)

          raise ArgumentError,
                "model_call_safety must be one of #{MODEL_CALL_SAFETIES.join(', ')}"
        end

        def validate_routing!
          return if Session::ROUTINGS.include?(routing.to_sym)

          raise ArgumentError, "routing must be one of #{Session::ROUTINGS.join(', ')}"
        end

        def validate_checkpointer!
          return if checkpointer.respond_to?(:durable?) && checkpointer.durable?

          raise ConfigurationError,
                'Tamoz::Agent::Session requires a durable checkpointer; use ' \
                'Tamoz::Agent::Runtime for ephemeral work'
        end

        # P10 §3 boundary: the agent never depends on tamoz-mcp; the
        # caller-supplied source is duck-typed.
        def validate_mcp_source!
          return unless mcp

          missing = MCP_SOURCE_METHODS.reject { |method| mcp.respond_to?(method) }
          return if missing.empty?

          raise ArgumentError, "mcp source must respond to #{missing.join(', ')}"
        end

        # P8 §5.2: the toolbox must expose exactly the capability surface the
        # profile pins; a mismatch fails here, before any model I/O.
        def verify_profile_binding!
          return unless profile

          verify_catalog_binding!
          verify_root_binding!
        end

        def verify_catalog_binding!
          expected = profile.policy.fetch('tool_catalog_digest')
          return if catalog_bound?(expected)

          pinned = [expected, profile.policy['unattended_catalog_digest']].compact.join(' or ')
          raise Profile::ValidationError,
                "toolbox catalog digest #{toolbox.catalog_digest} does not match " \
                "profile #{profile.profile_id.inspect} policy.tool_catalog_digest #{pinned}"
        end

        def catalog_bound?(expected)
          legacy_digest = profile.policy['unattended_catalog_digest']
          toolbox.catalog_digest == expected ||
            (legacy_digest && toolbox.catalog_digest == legacy_digest) ||
            narrowed_catalog_matches?
        end

        def narrowed_catalog_matches?
          profile_narrowed && (toolbox.allowed_tools - profile.tools_allowed).empty?
        end

        def verify_root_binding!
          return if toolbox.root.to_s == File.expand_path(profile.canonical_root)

          raise Profile::ValidationError,
                "toolbox root #{toolbox.root} does not match profile canonical_root " \
                "#{profile.canonical_root.inspect}"
        end
      end
    end
  end
end
