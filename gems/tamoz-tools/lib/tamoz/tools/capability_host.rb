# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Tools
    # P18 (docs/P18_CAPABILITY_HOST_PLAN.md §2, C5) — the capability host that
    # tamoz-tools owns. Interface + registry + intersection renderer, NOT a
    # single dispatch body. The host is a RE-ORG of the toolbox surface, never
    # a surface change (H4): the model-visible ids and descriptions are
    # byte-identical to what the toolbox exposed before P18.
    #
    # The registry is built at session construction from the built-in sources
    # (local tools, skills; MCP/websearch register at the session level) with
    # the policy-derived ADMISSION SET (the already-intersected surface from
    # build_profile_toolbox + verify_profile_binding! — the host never
    # re-reads profile policy). It is SEALED after construction; a forged
    # registration fails (C3/C6).
    #
    # Dispatch (C7): the host calls the per-source dispatcher's validate/
    # execute uniformly — zero source-typed branches in the host. Typed errors
    # from any source pass through with class + message bytes identical; only
    # non-ToolError exceptions are wrapped at the boundary.
    class CapabilityHost
      INVENTORY_REASONS = %w[
        disabled invalid_configuration handshake_failed timeout catalog_digest_changed
        circuit_open missing_grant phase_invisible approval_required not_admitted unavailable
        unknown unconfigured uncatalogued unmaterialized unreachable unverified
      ].freeze

      def initialize(sources:, admission_set:)
        @registry = Tamoz::Core::Capability::Registry.build(
          sources:, admission_set:
        )
        @dispatchers = {}
      end

      attr_reader :registry

      # Pure projection of the sealed registry. It only reads descriptor data and
      # caller-provided health snapshots; it never asks a source to connect,
      # compile a catalog, or execute a probe.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/BlockLength, Metrics/PerceivedComplexity -- inventory keeps the full control-plane gate vector together.
      # Inventory is a pure projection of the complete control-plane gate vector;
      # keeping the gates together prevents an omitted dimension from becoming
      # an implicit success path.
      def inventory(
        configured_sources: nil,
        catalogued_sources: nil,
        materialized_sources: nil,
        reachable_sources: nil,
        authorized_ids: nil,
        verified_ids: nil,
        phase: :action,
        source_reasons: {}
      )
        configured = configured_sources&.map(&:to_s)
        catalogued = catalogued_sources&.map(&:to_s)
        materialized = materialized_sources&.map(&:to_s)
        reachable = reachable_sources&.map(&:to_s)
        authorized = authorized_ids&.map(&:to_s)
        verified = verified_ids&.map(&:to_s)
        registry.declared_descriptors.map do |id, descriptor|
          source = registry.source_for(id)
          source_id = source.source_id
          admitted = registry.admitted?(id)
          configured_value = gate(configured, source_id)
          catalogued_value = gate(catalogued, source_id)
          materialized_value = gate(materialized, source_id)
          reachable_value = gate(reachable, source_id)
          authorized_value = gate(authorized, id)
          verified_value = gate(verified, id)
          phase_visible = phase.to_sym == :discovery ? descriptor.effect_class == :read_only : true
          source_healthy = !source_reasons.key?(source_id)
          effective = admitted && phase_visible && descriptor.availability == :enabled &&
                      [configured_value, catalogued_value, materialized_value, reachable_value,
                       authorized_value, verified_value, source_healthy].all?(true)
          reason = inventory_reason(
            descriptor:, source_id:, configured: configured_value,
            catalogued: catalogued_value, materialized: materialized_value,
            reachable: reachable_value, authorized: authorized_value,
            verified: verified_value, admitted:, phase_visible:, effective:, source_reasons:
          )
          {
            "id" => id, "source_id" => source_id, "declared" => true,
            "configured" => configured_value, "catalogued" => catalogued_value,
            "materialized" => materialized_value, "reachable" => reachable_value,
            "authorized" => authorized_value, "effective" => effective,
            "verified" => verified_value,
            "phase_visible" => phase_visible,
            "approval_required" => descriptor.approval_policy == :required,
            "effect_class" => descriptor.effect_class.to_s,
            "schema_digest" => descriptor.schema_digest,
            "definition_digest" => descriptor.definition_digest,
            "reason" => reason
          }.freeze
        end.freeze
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/BlockLength, Metrics/PerceivedComplexity

      # Bind a per-source dispatcher (validate/execute). The host protocol
      # dispatches through the registry's sources uniformly.
      # A dispatcher may be bound to a registered source exactly once. Both
      # halves matter: binding an UNREGISTERED source would give a capability
      # the sealed registry never admitted a way in, and REBINDING a bound
      # source would let a later caller swap out the code that executes an
      # already-published capability — a sealed surface with a swappable
      # implementation is not sealed.
      def bind_dispatcher(source_id, dispatcher)
        unless @registry.sources.any? { |source| source.source_id == source_id }
          raise Tamoz::Core::Capability::DescriptorConflictError,
                "no registered capability source #{source_id.inspect}; the " \
                "registry is sealed at session construction"
        end
        if @dispatchers.key?(source_id)
          raise Tamoz::Core::Capability::DescriptorConflictError,
                "capability source #{source_id.inspect} already has a bound " \
                "dispatcher; a bound source is never re-implemented"
        end

        @dispatchers[source_id] = dispatcher
        self
      end

      # The dispatcher bound to one source. The session's tool-facing decisions
      # (approval, preview, effect intent, safety) run through the same
      # per-source dispatcher that executes the capability, so no decision can
      # be answered by a different source than the one that will act.
      def dispatcher_for(source_id)
        @dispatchers.fetch(source_id) do
          raise Tamoz::Core::Capability::DescriptorConflictError,
                "capability source #{source_id.inspect} has no bound dispatcher"
        end
      end

      # Resolve a model-visible id to its descriptor and the dispatcher of the
      # source that owns it. This is the routing itself — zero source-typed
      # branches — and it raises nothing but the host's own typed errors.
      #
      # Callers that must preserve the exact exception semantics of the code
      # they route (the durable session: invariant 17 requires storage failures
      # and programmer bugs to PROPAGATE rather than become tool evidence) use
      # `route` and call the dispatcher themselves. `dispatch` adds the D-7
      # boundary wrap on top for callers that want a typed result for every
      # outcome.
      def route(descriptor_id)
        descriptor = @registry.descriptors.fetch(descriptor_id) do
          # The message is `Toolbox#validate`'s, byte for byte, and must stay
          # that way: structural review feeds a rejection reason back into the
          # planning prompt, so changing this text changes the model's input
          # bytes and the cache epoch with them (invariant 16, P18 C7).
          raise ToolError, "unknown tool #{descriptor_id.inspect}"
        end
        source = @registry.source_for(descriptor_id)
        [descriptor, dispatcher_for(source.source_id)]
      end

      # The uniform dispatch protocol. Zero source-typed branches: the source
      # is looked up by the descriptor id, its dispatcher runs validate then
      # execute.
      def dispatch(descriptor_id, arguments, context: {})
        descriptor, dispatcher = route(descriptor_id)
        dispatcher.validate(descriptor, arguments)
        dispatcher.execute(descriptor, arguments, context:)
      rescue Tamoz::Error, Tamoz::Core::ToolError => error
        # A typed error from any source passes through with identity.
        raise error
      rescue StandardError => error
        # The host wraps ONLY non-ToolError exceptions (invariant 17).
        raise ToolError, "capability host wrapped #{error.class}: #{error.message}"
      end

      private

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity -- reason selection is the closed inventory protocol.
      def inventory_reason(
        descriptor:, source_id:, configured:, catalogued:, materialized:, reachable:,
        authorized:, verified:, admitted:, phase_visible:, effective:, source_reasons:
      )
        if source_reasons.key?(source_id)
          reason = source_reasons.fetch(source_id).to_s
          return reason if INVENTORY_REASONS.include?(reason)

          return "invalid_configuration"
        end
        return "disabled" if descriptor.availability == :disabled
        return "not_admitted" unless admitted
        return "missing_grant" unless authorized
        return "phase_invisible" unless phase_visible
        return "unconfigured" if configured == false
        return "uncatalogued" if catalogued == false
        return "unmaterialized" if materialized == false
        return "unreachable" if reachable == false
        return "unverified" if verified == false
        return "unknown" unless [configured, catalogued, materialized, reachable, authorized, verified].all?(true)
        return "approval_required" if !effective && descriptor.approval_policy == :required

        effective ? nil : "unavailable"
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity

      def gate(values, key)
        return nil if values.nil?

        values.include?(key)
      end
    end
  end
end
