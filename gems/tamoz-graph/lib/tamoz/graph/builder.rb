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
        managed: nil
      )
        if @channels.length >= MAX_CHANNELS
          raise GraphDefinitionError, "graph exceeds #{MAX_CHANNELS} state channels"
        end
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
          codec: @codec
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
        if @nodes.length >= MAX_NODES
          raise GraphDefinitionError, "graph exceeds #{MAX_NODES} nodes"
        end
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
        if @edges.length >= MAX_EDGES
          raise GraphDefinitionError, "graph exceeds #{MAX_EDGES} edges"
        end
        pair = [normalize_endpoint(source, source: true), normalize_endpoint(target, source: false)]
        raise GraphDefinitionError, "duplicate edge #{pair.inspect}" if @edges.include?(pair)

        @edges << pair.freeze
        pair
      end

      def branch(source, version:, targets:, name: nil, &router)
        raise ArgumentError, "a branch block is required" unless router
        if @branches.length >= MAX_BRANCHES
          raise GraphDefinitionError, "graph exceeds #{MAX_BRANCHES} branches"
        end

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

      def normalize_endpoint(value, source:)
        return START if source && value.equal?(START)
        return Tamoz::END if !source && value.equal?(Tamoz::END)
        if value.equal?(START) || value.equal?(Tamoz::END)
          raise GraphDefinitionError, "invalid edge endpoint #{value.inspect}"
        end

        Identifier.symbol(value, name: source ? "edge source" : "edge target")
      end

      private_constant :UNSET, :MAX_CHANNELS, :MAX_NODES, :MAX_EDGES, :MAX_BRANCHES
    end

    private_constant :Builder
  end
end
