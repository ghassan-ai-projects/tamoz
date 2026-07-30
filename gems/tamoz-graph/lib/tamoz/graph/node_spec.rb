# frozen_string_literal: true

module Tamoz
  module Graph
    class NodeSpec
      ROUTING_MODES = %i[static dynamic additive].freeze
      MAX_ROUTES = 65_536

      attr_reader :name, :callable, :implementation_name, :version, :routing, :routes

      def initialize(
        name:,
        callable:,
        graph_version:,
        implementation_name: nil,
        version: nil,
        routing: :static,
        routes: []
      )
        @name = Identifier.symbol(name, name: "node")
        raise GraphDefinitionError, "node #{@name} must be callable" unless callable.respond_to?(:call) ||
                                                                           callable.is_a?(Class)
        unless ROUTING_MODES.include?(routing)
          raise GraphDefinitionError, "node routing must be one of #{ROUTING_MODES.inspect}"
        end
        unless routes.is_a?(Array)
          raise GraphDefinitionError, "node routes must be an Array"
        end
        if routes.length > MAX_ROUTES
          raise GraphDefinitionError, "node #{@name} exceeds #{MAX_ROUTES} routes"
        end
        @routes = routes.map do |target|
          target.equal?(Tamoz::END) ? Tamoz::END : Identifier.symbol(target, name: "node route")
        end.uniq.freeze
        if routing == :static && !@routes.empty?
          raise GraphDefinitionError, "static node #{@name} cannot declare dynamic routes"
        end
        if routing != :static && @routes.empty?
          raise GraphDefinitionError, "#{routing} node #{@name} must declare routes"
        end

        stable_name = implementation_name || named_callable(callable)
        if stable_name.nil? || (callable.is_a?(Proc) && (implementation_name.nil? || version.nil?))
          raise GraphDefinitionError,
                "anonymous node #{@name} requires implementation_name and version"
        end

        @callable = callable
        @implementation_name = Identifier.identity(stable_name, name: "node implementation")
        @version = Identifier.version(version || graph_version, name: "node version")
        @routing = routing
        freeze
      end

      def call(state, context)
        if callable.is_a?(Class) && !callable.respond_to?(:call)
          callable.new.call(state, context)
        else
          callable.call(state, context)
        end
      end

      def descriptor
        {
          "name" => name.to_s,
          "implementation" => implementation_name,
          "version" => version,
          "routing" => routing.to_s,
          "routes" => routes.map do |target|
            target.equal?(Tamoz::END) ? "__end__" : target.to_s
          end.sort
        }
      end

      private

      def named_callable(value)
        value.name if value.is_a?(Module)
      end

      private_constant :ROUTING_MODES, :MAX_ROUTES
    end
  end
end
