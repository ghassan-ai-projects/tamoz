# frozen_string_literal: true

module Tamoz
  module Graph
    # Encodes and revives checkpoint routes.
    class CheckpointRoutes
      END_SIZE = 1
      PULL_SIZE = 2
      SEND_SIZE = 4

      def initialize(values)
        @values = values
        freeze
      end

      def encode_goto(routes)
        return nil if routes.nil?
        raise CheckpointCorruptionError, 'outcome routes must be an Array' unless routes.is_a?(Array)

        routes.map do |route|
          if route.equal?(Tamoz::END)
            ['end']
          elsif route.is_a?(Send)
            ['send', route.node.to_s, @values.dump_value(route.input), route.key]
          else
            ['pull', route.to_s]
          end
        end
      end

      def decode_goto(wire)
        return nil if wire.nil?

        @values.require_array!(wire, nil, 'outcome routes')
        wire.map.with_index do |route, index|
          decode_route(route, index)
        end.freeze
      end

      def decode_route(route, index)
        @values.require_array!(route, nil, "route[#{index}]")
        case route.fetch(0, nil)
        when 'end'
          @values.require_array!(route, END_SIZE, "route[#{index}]")
          Tamoz::END
        when 'pull'
          @values.require_array!(route, PULL_SIZE, "route[#{index}]")
          @values.node!(route.fetch(1), "route[#{index}] node")
        when 'send'
          @values.require_array!(route, SEND_SIZE, "route[#{index}]")
          Send.new(
            node: @values.node!(route.fetch(1), "route[#{index}] node"),
            input: @values.load_value(route.fetch(2)),
            key: @values.optional_string!(route.fetch(3), "route[#{index}] key")
          )
        else
          raise CheckpointCorruptionError,
                "route[#{index}] has an unknown kind"
        end
      end
    end

    private_constant :CheckpointRoutes
  end
end
