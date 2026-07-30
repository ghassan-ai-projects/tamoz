# frozen_string_literal: true

module Tamoz
  module Graph
    class Definition
      attr_reader :name, :version, :channels, :nodes, :edges, :branches

      def initialize(name:, version:, channels:, nodes:, edges:, branches:)
        @name = Identifier.string(name, name: "graph name")
        @version = Identifier.version(version, name: "graph version")
        @channels = channels.sort_by { |key, _value| key.to_s }.to_h.freeze
        @nodes = nodes.sort_by { |key, _value| key.to_s }.to_h.freeze
        @edges = edges.map(&:freeze).sort_by do |source, target|
          [endpoint_name(source), endpoint_name(target)]
        end.freeze
        @branches = branches.sort_by(&:name).freeze
        freeze
      end

      def compile(**options)
        Compiler.new(self, **options).compile
      end

      private

      def endpoint_name(value)
        return "__start__" if value.equal?(START)
        return "__end__" if value.equal?(Tamoz::END)

        value.to_s
      end
    end
  end
end
