# frozen_string_literal: true

module Tamoz
  module Graph
    Frontier = Data.define(
      :node,
      :kind,
      :path,
      :input,
      :activation_checkpoint_id,
      :logical_step
    ) do
      def initialize(
        node:,
        kind:,
        path:,
        input: nil,
        activation_checkpoint_id: nil,
        logical_step:
      )
        normalized_node = Identifier.symbol(node, name: "frontier node")
        unless %i[pull push].include?(kind)
          raise ConfigurationError, "frontier kind must be pull or push"
        end
        unless path.is_a?(Array) && !path.empty?
          raise ConfigurationError, "frontier path must be a non-empty Array"
        end
        normalized_path = path.map do |part|
          Identifier.version(part, name: "frontier path part")
        end.freeze
        normalized_input = input.nil? ? nil : StateCodec.new.normalize(input)
        unless logical_step.is_a?(Integer) && logical_step.positive?
          raise ConfigurationError, "logical_step must be positive"
        end

        super(
          node: normalized_node,
          kind:,
          path: normalized_path,
          input: normalized_input,
          activation_checkpoint_id: activation_checkpoint_id&.dup&.freeze,
          logical_step:
        )
      end

      def with_activation_checkpoint(id)
        with(activation_checkpoint_id: String(id))
      end

      def descriptor
        {
          "node" => node.to_s,
          "kind" => kind.to_s,
          "path" => path,
          "input" => input,
          "activation_checkpoint_id" => activation_checkpoint_id,
          "logical_step" => logical_step
        }
      end
    end

    private_constant :Frontier
  end
end
