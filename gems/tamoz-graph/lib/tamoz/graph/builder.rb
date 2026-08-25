# frozen_string_literal: true

module Tamoz
  module Graph
    class Builder
      UNSET = Object.new.freeze
      MAX_CHANNELS = 10_000
      MAX_NODES = 10_000
      MAX_EDGES = 100_000
      MAX_BRANCHES = 10_000

      def self.build(name:, version:, &block)
        builder = new(name:, version:)
        builder.instance_eval(&block)
        builder.definition
      end

      def initialize(name:, version:)
        @name = Identifier.string(name, name: "graph name")
        @version = Identifier.version(version, name: "graph version")
        @codec = StateCodec.new
        @channels = {}
        @nodes = {}
        @edges = []
        @branches = []
      end

      def state(
        name,
        reduce: nil,
        reducer_name: nil,
        reducer_version: nil,
        default: UNSET,
        default_name: nil,
        default_version: nil,
        managed: nil,
        immutable: false
      )
        enforce_capacity!(@channels.length, MAX_CHANNELS, "state channels")
        key = Identifier.symbol(name, name: "state channel")
        raise GraphDefinitionError, "duplicate state channel #{key}" if @channels.key?(key)

        actual_default = default.equal?(UNSET) ? nil : default
        reducer = Reducers.resolve(reduce, name: reducer_name, version: reducer_version)
        @channels[key] = Channel.new(
          name: key,
          reducer:,
          default: actual_default,
          default_name:,
          default_version:,
          managed:,
          codec: @codec,
          immutable:
        )
        key
      end

      def node(
        name,
        callable = nil,
        implementation_name: nil,
        version: nil,
        routing: :static,
        routes: [],
        &block
      )
        enforce_capacity!(@nodes.length, MAX_NODES, "nodes")
        key = Identifier.symbol(name, name: "node")
        raise GraphDefinitionError, "duplicate node #{key}" if @nodes.key?(key)
        if callable && block
          raise GraphDefinitionError, "node #{key} accepts a callable or block, not both"
        end

        behavior = callable || block
        @nodes[key] = NodeSpec.new(
          name: key,
          callable: behavior,
          implementation_name:,
          version:,
          routing:,
          routes:,
          graph_version: @version
        )
        key
      end

      def edge(source, target)
        enforce_capacity!(@edges.length, MAX_EDGES, "edges")
        pair = [normalize_source(source), normalize_target(target)]
        raise GraphDefinitionError, "duplicate edge #{pair.inspect}" if @edges.include?(pair)

        @edges << pair.freeze
        pair
      end

      def branch(source, version:, targets:, name: nil, &router)
        raise ArgumentError, "a branch block is required" unless router
        enforce_capacity!(@branches.length, MAX_BRANCHES, "branches")

        value = Branch.new(source:, name:, version:, targets:, router:)
        if @branches.any? { |entry| entry.source == value.source && entry.name == value.name }
          raise GraphDefinitionError, "duplicate branch #{value.name}"
        end
        @branches << value
        value
      end

      def definition
        Definition.new(
          name: @name,
          version: @version,
          channels: @channels,
          nodes: @nodes,
          edges: @edges,
          branches: @branches
        )
      end

      private

      def normalize_source(value)
        return START if value.equal?(START)
        raise GraphDefinitionError, "invalid edge endpoint #{value.inspect}" if value.equal?(Tamoz::END)

        Identifier.symbol(value, name: "edge source")
      end

      def normalize_target(value)
        return Tamoz::END if value.equal?(Tamoz::END)
        raise GraphDefinitionError, "invalid edge endpoint #{value.inspect}" if value.equal?(START)

        Identifier.symbol(value, name: "edge target")
      end

      def enforce_capacity!(current, maximum, what)
        return if current < maximum

        raise GraphDefinitionError, "graph exceeds #{maximum} #{what}"
      end

      private_constant :UNSET, :MAX_CHANNELS, :MAX_NODES, :MAX_EDGES, :MAX_BRANCHES
    end

    private_constant :Builder
  end
end
