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
      def initialize(sources:, admission_set:)
        @registry = Tamoz::Core::Capability::Registry.build(
          sources:, admission_set:
        )
        @dispatchers = {}
      end

      attr_reader :registry

      # Bind a per-source dispatcher (validate/execute). The host protocol
      # dispatches through the registry's sources uniformly.
      def bind_dispatcher(source_id, dispatcher)
        @dispatchers[source_id] = dispatcher
        self
      end

      # The uniform dispatch protocol. Zero source-typed branches: the source
      # is looked up by the descriptor id, its dispatcher runs validate then
      # execute.
      def dispatch(descriptor_id, arguments, context: {})
        descriptor = @registry.descriptors.fetch(descriptor_id)
        source = @registry.source_for(descriptor_id)
        dispatcher = @dispatchers.fetch(source.source_id)
        dispatcher.validate(descriptor, arguments)
        dispatcher.execute(descriptor, arguments, context:)
      rescue Tamoz::Error, Tamoz::Core::ToolError => error
        # A typed error from any source passes through with identity.
        raise error
      rescue StandardError => error
        # The host wraps ONLY non-ToolError exceptions (invariant 17).
        raise ToolError, "capability host wrapped #{error.class}: #{error.message}"
      end
    end
  end
end
