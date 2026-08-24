# frozen_string_literal: true

require_relative "child_task_dispatcher"

module Tamoz
  module Agent
    # P15-W (docs/P18_CAPABILITY_HOST_PLAN.md §9) — the production binding of
    # the P18 capability host.
    #
    # P18 shipped the contract, the sealed registry, the intersection renderer
    # and the real dispatch paths, but deliberately deferred WIRING them into
    # session construction so the phase could not put its own hard-zero surface
    # gates at risk. This is that wiring:
    #
    #   * the registry is built ONCE at session construction, from the four
    #     built-in sources — `local`, `skill:<catalog>`, `mcp:<server>` and
    #     `websearch:<server>` — and sealed (invariant 42: a fifth or forged
    #     source fails at construction, and no content path can build one);
    #   * the invariant-35 intersection is computed from the POLICY-DERIVED
    #     admission set (`Toolbox#allowed_tools` for the toolbox sources, the
    #     caller-pinned descriptor ids for MCP). The host never re-reads profile
    #     policy — `Session#verify_profile_binding!` remains that authority;
    #   * every tool-facing decision the session makes — surface, approval,
    #     preview, effect intent, safety, validation and execution — routes
    #     through the per-source dispatcher for the descriptor's source, with
    #     zero source-typed branches left in the session nodes.
    #
    # The model-visible surface is byte-identical to the pre-wiring surface.
    # `ordered_names` pins the ORDER to the toolbox's own catalog order followed
    # by the MCP source's, because the tool list is rendered into the planning
    # prompt and a reordering would change the prompt bytes (invariant 16).
    # Registry membership, not the order list, decides what is exposed: an id
    # the sealed registry does not admit can never be rendered or dispatched.
    class CapabilityBinding
      Core = Tamoz::Core
      Capability = Tamoz::Core::Capability

      # The MCP server id P17 reserves for the governed websearch capability.
      # Its descriptors keep their pinned model-visible `mcp:websearch/...` ids
      # (C5) while registering under the `websearch:` built-in source, which is
      # what makes websearch one of the four closed-world sources rather than an
      # unnamed extra MCP server.
      WEBSEARCH_SERVER_ID = "websearch"
      MCP_EFFECT_CLASSES = %i[read_only bounded reconcilable].freeze
      SKILL_TOOLS = %w[load_skill read_skill_resource].freeze

      def self.build(toolbox:, mcp: nil, child_task_runtime: nil, profile: nil)
        new(toolbox:, mcp:, child_task_runtime:, profile:)
      end

      def initialize(toolbox:, mcp: nil, child_task_runtime: nil, profile: nil)
        @toolbox = toolbox
        @mcp = mcp
        child = child_dispatcher(child_task_runtime, profile)
        local = BoundLocalDispatcher.new(toolbox, child:)

        sources, dispatchers = build_toolbox_bindings(child, local, toolbox)
        remote_sources, remote_dispatchers = build_remote_bindings(mcp)
        sources.concat(remote_sources)
        dispatchers.merge!(remote_dispatchers)

        @child_enabled = !child.nil?
        @descriptions = build_descriptions(toolbox, child)
        @host = build_host(sources, dispatchers)
        @ordered_names = build_ordered_names(toolbox, child, mcp)
        freeze
      end

      attr_reader :host, :toolbox, :mcp, :descriptions

      def registry = host.registry

      # The model-visible surface for one phase, in the pinned order. Discovery
      # sees only read-only capabilities (invariant 55: discovery cannot act).
      def names(phase)
        read_only = phase == :discovery
        @ordered_names.select do |name|
          descriptor = registry.descriptors[name]
          next false unless descriptor

          !read_only || descriptor.effect_class == :read_only
        end
      end

      def descriptor?(name) = registry.descriptors.key?(String(name))

      def inventory(**)
        host.inventory(**)
      end

      def validate(name, arguments)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.validate(descriptor, arguments)
      end

      # Invariant 17 is why this routes with `route` instead of the host's
      # `dispatch` convenience: the durable session must let a storage failure,
      # a cancellation or a programmer bug PROPAGATE out of the effect journal.
      # `CapabilityHost#dispatch` wraps every untyped exception into a
      # `ToolError`, and `EffectDispatcher` turns a `ToolError` into recorded
      # tool EVIDENCE — so dispatching here would silently convert an
      # `Errno::ENOSPC` or a `NoMethodError` into something the agent may try
      # to repair around. The routing is the host's; the exception semantics
      # stay exactly what they were before the host existed.
      def execute(context, name, arguments)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.execute(descriptor, arguments, context:)
      end

      def preview(name, arguments)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.preview(descriptor, arguments)
      end

      def effect_intent(name, arguments)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.effect_intent(descriptor, arguments)
      end

      # The closed effect class of the host descriptor — the value the
      # approval engine's request carries (read_only ⇒ read invariant).
      def effect_class(name)
        descriptor, = host.route(String(name))
        descriptor.effect_class.to_sym
      end

      def maximum_effect_output_bytes(name)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.maximum_effect_output_bytes(descriptor)
      end

      def safety(name, arguments)
        descriptor, dispatcher = host.route(String(name))
        dispatcher.safety(descriptor, arguments)
      end

      # True for capabilities the MCP source owns (MCP servers and websearch).
      # The session still needs this for the two MCP-specific renderings — the
      # catalog-derived planning descriptions and the source-qualified surface
      # — which are properties of the MCP catalog, not of dispatch.
      def mcp_capability?(name)
        descriptor = registry.descriptors[String(name)]
        return false unless descriptor

        %i[mcp_tool websearch].include?(descriptor.kind)
      end

      def remote_planning_surface(allowed)
        allowed.filter_map { |name| mcp_entry(@mcp, name) if @mcp }.to_h.freeze
      end

      private

      def child_dispatcher(runtime, profile)
        return unless runtime && profile

        ChildTaskDispatcher.new(runtime:, profile:)
      end

      # Invariant 35: the admission set is policy-derived, computed BEFORE the
      # host exists. `Toolbox#allowed_tools` is the already-intersected profile
      # surface; the MCP ids are the caller's pinned catalog descriptors, which
      # `Session#verify_mcp_binding!` pins across resume.
      def admission_set
        @toolbox.allowed_tools +
          (@child_enabled ? [ChildTaskDispatcher::TOOL_NAME] : []) +
          (@mcp ? @mcp.names : [])
      end

      def build_toolbox_source(source_id, names, toolbox)
        read_only = toolbox.read_only_names
        descriptors = names.map { |name| build_toolbox_descriptor(name, source_id, read_only) }
        Capability::Source.new(source_id:, descriptors:)
      end

      def mcp_entry(source, name)
        return unless source.name?(name)

        descriptor = source.descriptor_for(name)
        snapshot = source.catalogs[descriptor.source_id]
        entry = snapshot&.entries&.find { |candidate| candidate.name == descriptor.name }
        description = entry&.description
        return if description.nil? || description.empty?

        [name, String(description).encode("UTF-8", invalid: :replace, undef: :replace)
                              .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, '')]
      end

      # One built-in source per MCP server, so a two-server session composes
      # through the same closed protocol as a one-server session (P18 H3).
      def grouped_mcp_descriptors
        return {} unless @mcp

        @mcp.descriptors.group_by { |descriptor| source_id_for(descriptor) }
            .transform_values do |descriptors|
              descriptors.map { |descriptor| mcp_descriptor(descriptor) }
            end
      end

      # Fail closed, never drop: an MCP tool the operator did not declare
      # read-only carries the caller's `:unknown_effects` (or any class outside
      # the closed capability set). It is admitted as `:bounded` — unsafe,
      # approval-required, non-retryable — so an ambiguous remote effect is
      # governed through review and approval rather than silently unavailable.
      def closed_effect_class(descriptor)
        effect_class = optional(descriptor, :effect_class)&.to_sym
        MCP_EFFECT_CLASSES.include?(effect_class) ? effect_class : :bounded
      end

      def source_id_for(descriptor)
        if descriptor.source_id == WEBSEARCH_SERVER_ID
          "websearch:#{descriptor.source_id}"
        else
          "mcp:#{descriptor.source_id}"
        end
      end

      # P10 §3 keeps the MCP descriptor DUCK-TYPED: the source guarantees only
      # `id`, `name`, `source_id`, `definition_digest` and `effect_class`. The
      # host descriptor is built from exactly that contract, plus the optional
      # schema/profile fields when the caller's descriptor carries them —
      # reading a field the contract does not promise would make the host
      # reject a conforming caller.
      def mcp_descriptor(descriptor)
        effect_class = closed_effect_class(descriptor)
        source_id = source_id_for(descriptor)
        input_schema = optional(descriptor, :input_schema)
        output_schema = optional(descriptor, :output_schema)

        Capability::Descriptor.new(
          id: descriptor.id,
          kind: mcp_kind(descriptor),
          source_id:,
          source_digest: Capability::Descriptor.source_digest_for(source_id),
          trust: :operator,
          effect_class:,
          approval_policy: mcp_approval_policy(effect_class),
          egress_policy_ref: mcp_egress_policy(descriptor),
          egress_policy_digest: Capability::Descriptor.egress_digest_for(mcp_egress_policy(descriptor)),
          secret_handling: :reject_values,
          request_budget: {"max_bytes" => 16 * 1024},
          output_budget: {"max_bytes" => 64 * 1024},
          retry_policy: mcp_retry_policy(effect_class),
          reconciliation_policy: mcp_reconciliation_policy(effect_class),
          schema_digest: Capability::Descriptor.schema_digest_for(input_schema, output_schema),
          protocol_profile: mcp_protocol_profile(descriptor),
          input_schema: schema_shape(input_schema),
          output_schema: schema_shape(output_schema)
        )
      end

      def optional(descriptor, field)
        descriptor.respond_to?(field) ? descriptor.public_send(field) : nil
      end

      # The host records THAT a schema is pinned, never a copy of it: the
      # pinned schema stays in the caller's source, which is the only thing
      # allowed to validate against it (P10 §4).
      def schema_shape(schema)
        schema.nil? ? nil : Tamoz::Core.deep_freeze(Tamoz::Core.canonical(schema))
      end

      def build_toolbox_bindings(child, local, toolbox)
        sources = []
        dispatchers = {}
        local_names, skill_names = partition_tool_names(toolbox)

        local_names << ChildTaskDispatcher::TOOL_NAME if child
        sources << build_toolbox_source("local", local_names, toolbox)
        dispatchers["local"] = local

        unless skill_names.empty?
          skill_source_id = "skill:#{toolbox.skill_epoch}"
          sources << build_toolbox_source(skill_source_id, skill_names, toolbox)
          dispatchers[skill_source_id] = local
        end

        [sources, dispatchers]
      end

      def partition_tool_names(toolbox)
        toolbox.names.partition { |name| !SKILL_TOOLS.include?(name) }
      end

      def build_remote_bindings(mcp)
        return [[], {}] unless mcp

        dispatcher = McpDispatcher.new(mcp)
        sources = []
        dispatchers = {}
        grouped_mcp_descriptors.each do |source_id, descriptors|
          sources << Capability::Source.new(source_id:, descriptors:)
          dispatchers[source_id] = dispatcher
        end
        [sources, dispatchers]
      end

      def build_descriptions(toolbox, child)
        descriptions = toolbox.descriptions.dup
        descriptions[ChildTaskDispatcher::TOOL_NAME] = ChildTaskDispatcher::DESCRIPTION if child
        descriptions.freeze
      end

      def build_host(sources, dispatchers)
        host = Tamoz::Tools::CapabilityHost.new(sources:, admission_set: admission_set)
        dispatchers.each { |source_id, dispatcher| host.bind_dispatcher(source_id, dispatcher) }
        host
      end

      def build_ordered_names(toolbox, child, mcp)
        (toolbox.names + (child ? [ChildTaskDispatcher::TOOL_NAME] : []) +
          (mcp ? mcp.names : [])).uniq.freeze
      end

      def build_toolbox_descriptor(name, source_id, read_only_names)
        input_schema = {"type" => "object"}
        output_schema = {"type" => "object"}
        skill = SKILL_TOOLS.include?(name)
        read_only = read_only_names.include?(name)

        Capability::Descriptor.new(
          id: name,
          kind: skill ? :skill : :tool,
          source_id:,
          trust: skill ? :declared : :local,
          effect_class: read_only ? :read_only : :bounded,
          approval_policy: read_only ? :none : :required,
          egress_policy_ref: "none",
          egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
          secret_handling: :reject_values,
          request_budget: {"max_bytes" => 16 * 1024},
          output_budget: {"max_bytes" => 64 * 1024},
          retry_policy: read_only ? :read_only : :none,
          reconciliation_policy: :none,
          schema_digest: Capability::Descriptor.schema_digest_for(input_schema, output_schema),
          source_digest: Capability::Descriptor.source_digest_for(source_id),
          protocol_profile: {"transport" => "in_process"},
          input_schema:,
          output_schema:
        )
      end

      def websearch?(descriptor)
        descriptor.source_id == WEBSEARCH_SERVER_ID
      end

      def mcp_kind(descriptor)
        websearch?(descriptor) ? :websearch : :mcp_tool
      end

      def mcp_egress_policy(descriptor)
        websearch?(descriptor) ? "websearch:#{descriptor.source_id}" : "mcp:#{descriptor.source_id}"
      end

      def mcp_protocol_profile(descriptor)
        profile = optional(descriptor, :protocol_profile)
        {
          "transport" => "mcp",
          "profile" => profile.nil? ? "" : profile.to_s,
          "definition_digest" => descriptor.definition_digest
        }
      end

      def mcp_approval_policy(effect_class)
        effect_class == :read_only ? :none : :required
      end

      def mcp_retry_policy(effect_class)
        effect_class == :read_only ? :read_only : :none
      end

      def mcp_reconciliation_policy(effect_class)
        effect_class == :reconcilable ? :explicit : :none
      end
    end

    # Keeps the existing Toolbox dispatcher as the local implementation while
    # adding the one durable child capability to the same sealed source.
    class BoundLocalDispatcher
      def initialize(toolbox, child: nil)
        @local = Tamoz::Tools::LocalDispatcher.new(toolbox)
        @child = child
        freeze
      end

      def validate(descriptor, arguments)
        dispatcher_for(descriptor).validate(descriptor, arguments)
      end

      def execute(descriptor, arguments, context: nil)
        dispatcher_for(descriptor).execute(descriptor, arguments, context:)
      end

      def preview(descriptor, arguments)
        dispatcher_for(descriptor).preview(descriptor, arguments)
      end

      def effect_intent(descriptor, arguments)
        dispatcher_for(descriptor).effect_intent(descriptor, arguments)
      end

      def maximum_effect_output_bytes(descriptor)
        dispatcher_for(descriptor).maximum_effect_output_bytes(descriptor)
      end

      def safety(descriptor, arguments)
        dispatcher_for(descriptor).safety(descriptor, arguments)
      end

      private

      def dispatcher_for(descriptor)
        child?(descriptor) ? @child : @local
      end

      def child?(descriptor)
        descriptor.id == ChildTaskDispatcher::TOOL_NAME
      end
    end

    # The per-source dispatcher for the MCP-owned sources (`mcp:<server>` and
    # `websearch:<server>`). Every method forwards to the caller-supplied
    # source by the descriptor's pinned model-visible id, so the source stays
    # the single implementation of the MCP contract and the host adds nothing.
    class McpDispatcher
      def initialize(source)
        @source = source
        freeze
      end

      attr_reader :source

      def validate(descriptor, arguments)
        forward_to_source(descriptor, :validate, arguments)
      end

      def execute(descriptor, arguments, context: nil)
        source.execute(context, descriptor.id, arguments)
      end

      def preview(descriptor, arguments)
        forward_to_source(descriptor, :preview, arguments)
      end

      def effect_intent(descriptor, arguments)
        forward_to_source(descriptor, :effect_intent, arguments)
      end

      def maximum_effect_output_bytes(descriptor)
        source.maximum_effect_output_bytes(descriptor.id)
      end

      def safety(descriptor, _arguments)
        source.read_only?(descriptor.id) ? :read_only : :unsafe
      end

      private

      def forward_to_source(descriptor, method, *)
        source.public_send(method, descriptor.id, *)
      end
    end
  end
end
