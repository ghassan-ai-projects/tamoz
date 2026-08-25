# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    # Caller-supplied source of governed MCP capabilities (P10 §3/§5/§6).
    #
    # tamoz-agent holds no hard dependency on tamoz-mcp: everything here is
    # duck-typed, and the source itself is a frozen container the caller builds
    # from an immutable compiled catalog snapshot. The caller compiles one
    # catalog per server with `Tamoz::Mcp::Catalog.compile`, builds a descriptor
    # per admitted capability (typically via
    # `Tamoz::Mcp::Invocation.descriptor_for`, which pins the snapshot entry's
    # definition digest), and supplies the callables that render the MCP side of
    # the tool/effect contracts:
    #
    #   executor:  performs the invocation through the caller's own effect
    #              journal plumbing (P10 §6: exactly-once is the caller's journal,
    #              never a client-side retry). Receives (context, descriptor,
    #              arguments) and returns the observation output; raises the
    #              agent ToolError taxonomy for MCP failures.
    #   validator: no-I/O argument check used by structural review and the intent
    #              preflight, so a schema-invalid MCP step is a plan-time
    #              repairable rejection, never an execution surprise.
    #   previewer: the approval preview, rendered from approved-surface
    #              identifiers and arguments only (P10 §4 preview rule).
    #   effect_intent_builder: extra `effect_intent` fields (none in v1; MCP
    #              effects carry no path/before-state, so they are never
    #              filesystem-reconciled).
    #
    # The session consumes the source at three boundaries only: the planning
    # surface (names/descriptions), the step gate (approval, preview, intent,
    # output budget, safety), and step execution (the caller's executor inside
    # the ordinary effect journal). The source never widens the toolbox, never
    # reads server content into policy, and never recompiles a catalog: a changed
    # server can only produce a *candidate* source, which a resumed session
    # rejects at the binding guard.
    class McpCapabilitySource
      MAX_ARGUMENT_DEPTH = 100
      # The plan caps MCP output at 64 KiB (ServerConfig::Budgets); this is the
      # source-level bound the session's observation-budget preflight uses when
      # the caller does not declare a tighter one.
      DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024

      attr_reader :catalogs, :descriptors, :mcp_catalogs, :mcp_source_digests,
                  :names, :read_only_names

      def initialize(
        catalogs:,
        descriptors:,
        executor:,
        validator: nil,
        previewer: nil,
        effect_intent_builder: nil,
        closer: nil,
        maximum_effect_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
        source_digests: {}
      )
        validate_constructor_args!(catalogs, descriptors, executor, maximum_effect_output_bytes)

        @catalogs = deep_freeze(catalogs.transform_values { |snapshot| validate_snapshot!(snapshot) })
        @descriptors = validate_descriptors!(descriptors, @catalogs)
        @executor = executor
        @validator = validator
        @previewer = previewer
        @effect_intent_builder = effect_intent_builder
        @closer = closer
        @maximum_effect_output_bytes = maximum_effect_output_bytes
        @mcp_catalogs = build_catalog_digests(@catalogs)
        @mcp_source_digests = source_digests.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @names, @read_only_names, @name_index = build_descriptor_indexes(@descriptors)
        freeze
      end

      def close
        @closer&.call
        nil
      end

      # P10 §5 epoch pin: {server_id => snapshot_digest}. The session record pins
      # this exactly, and the resume guard compares it to the caller's current
      # source. `{}` (no catalogs) is the legacy sentinel.
      def empty? = @catalogs.empty?

      # Per-capability output bound the session's observation-budget preflight
      # uses (the plan caps MCP output at 64 KiB).
      def maximum_effect_output_bytes(_name)
        @maximum_effect_output_bytes
      end

      def name?(name) = @name_index.key?(String(name))
      def descriptor_for(name) = @name_index[String(name)]

      def descriptor_for!(name)
        descriptor_for(name) || raise(ToolError, "unknown tool #{String(name).inspect}")
      end

      def source_id_for(name)
        descriptor_for!(name).source_id
      end

      def read_only?(name)
        read_only_descriptor?(descriptor_for!(name))
      end

      def validate(name, arguments)
        descriptor = descriptor_for!(name)
        arguments = normalize_arguments!(descriptor, arguments)
        assert_depth!(descriptor, arguments, 0)
        @validator.call(descriptor, arguments) if @validator
        arguments
      end

      # Deterministic, side-effect-free description of what the MCP call would
      # do, in the terms the crash journal needs. v1 MCP effects carry no
      # path/before-state, so the base is empty and only caller-declared extra
      # fields (e.g. a caller-side effect key) are added.
      def effect_intent(name, arguments)
        validate(name, arguments)
        return {} unless @effect_intent_builder

        @effect_intent_builder.call(descriptor_for!(name), arguments) || {}
      end

      # The approval preview. The default renders the source-qualified capability
      # id and the canonical arguments — all approved-surface identifiers — so a
      # server payload string can never appear here.
      def preview(name, arguments)
        descriptor = descriptor_for!(name)
        return @previewer.call(descriptor, arguments) if @previewer

        "MCP #{descriptor.id}\narguments: #{JSON.generate(Deliberation.canonical(arguments))}"
      end

      # Runs the capability through the caller's executor inside the session's
      # ordinary effect journal (SessionNodes#step_execute wraps this call in
      # EffectDispatcher.run). The caller decides the exact tamoz-mcp → agent
      # taxonomy mapping; the session never sees a Tamoz::Mcp constant.
      def execute(context, name, arguments)
        @executor.call(context, descriptor_for!(name), arguments)
      end

      private

      def validate_snapshot!(snapshot)
        unless snapshot.respond_to?(:server_id) && snapshot.respond_to?(:snapshot_digest) &&
               snapshot.respond_to?(:entries) && snapshot.entries.is_a?(Array)
          raise ArgumentError,
                "each catalog snapshot must respond to server_id, snapshot_digest, and entries"
        end
        unless Tamoz::Core.valid_digest?(snapshot.snapshot_digest)
          raise ArgumentError, "snapshot_digest must be a sha256 digest"
        end

        snapshot
      end

      def validate_descriptors!(descriptors, catalogs)
        seen = {}
        descriptors.map do |descriptor|
          assert_descriptor_interface!(descriptor)
          record_unique_descriptor!(descriptor, seen)
          assert_descriptor_identity!(descriptor)
          assert_descriptor_pinning!(descriptor, catalogs)

          descriptor.freeze
        end.freeze
      end

      def read_only_descriptor?(descriptor)
        return descriptor.read_only? if descriptor.respond_to?(:read_only?)

        descriptor.effect_class.to_sym == :read_only
      end

      def assert_depth!(descriptor, value, depth)
        if depth > MAX_ARGUMENT_DEPTH
          raise ToolArgumentError,
                "the arguments for #{descriptor.id} exceed the maximum nesting depth " \
                "of #{MAX_ARGUMENT_DEPTH}"
        end

        case value
        when Hash
          value.each_value { |child| assert_depth!(descriptor, child, depth + 1) }
        when Array
          value.each { |child| assert_depth!(descriptor, child, depth + 1) }
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, entry|
            key.freeze if key.is_a?(String)
            deep_freeze(entry)
          end
        when Array
          value.each { |entry| deep_freeze(entry) }
        when String
          value.freeze
        end
        value.freeze
      end

      def validate_constructor_args!(catalogs, descriptors, executor, maximum_effect_output_bytes)
        unless catalogs.is_a?(Hash)
          raise ArgumentError, "catalogs must be a Hash of server_id => snapshot"
        end
        unless descriptors.is_a?(Array)
          raise ArgumentError, "descriptors must be an Array"
        end
        unless executor.respond_to?(:call)
          raise ArgumentError, "executor must respond to call(context, descriptor, arguments)"
        end
        unless maximum_effect_output_bytes.is_a?(Integer) &&
               maximum_effect_output_bytes.positive?
          raise ArgumentError, "maximum_effect_output_bytes must be a positive Integer"
        end
      end

      def build_catalog_digests(catalogs)
        catalogs
          .sort
          .to_h { |server_id, snapshot| [server_id, snapshot.snapshot_digest] }
          .freeze
      end

      def build_descriptor_indexes(descriptors)
        names = descriptors.map(&:id).freeze
        read_only_names = descriptors.select { |entry| read_only_descriptor?(entry) }
                                     .map(&:id).freeze
        name_index = descriptors.to_h { |entry| [entry.id, entry] }.freeze
        [names, read_only_names, name_index]
      end

      def assert_descriptor_interface!(descriptor)
        required = %i[id name source_id definition_digest effect_class]
        missing = required.reject { |method| descriptor.respond_to?(method) }
        return if missing.empty?

        raise ArgumentError,
              "each MCP descriptor must respond to #{missing.join(", ")}"
      end

      def record_unique_descriptor!(descriptor, seen)
        if seen.key?(descriptor.id)
          raise ArgumentError, "duplicate MCP capability name #{descriptor.id.inspect}"
        end

        seen[descriptor.id] = true
      end

      def assert_descriptor_identity!(descriptor)
        expected = "mcp:#{descriptor.source_id}/#{descriptor.name}"
        return if descriptor.id == expected

        raise ArgumentError,
              "MCP descriptor id #{descriptor.id.inspect} must be " \
              "#{expected.inspect} (source-qualified)"
      end

      def assert_descriptor_pinning!(descriptor, catalogs)
        snapshot = catalogs[descriptor.source_id]
        unless snapshot
          raise ArgumentError,
                "MCP descriptor #{descriptor.id.inspect} names server " \
                "#{descriptor.source_id.inspect} which has no pinned catalog"
        end

        entry = snapshot.entries.find { |candidate| candidate.name == descriptor.name }
        return if entry && entry.definition_digest == descriptor.definition_digest

        raise ArgumentError,
              "MCP descriptor #{descriptor.id.inspect} definition digest does not " \
              "match the pinned catalog snapshot"
      end

      def normalize_arguments!(descriptor, arguments)
        arguments = {} if arguments.nil?
        unless arguments.is_a?(Hash)
          raise ToolArgumentError,
                "the arguments for #{descriptor.id} must be a JSON object"
        end

        arguments
      end
    end
  end
end
