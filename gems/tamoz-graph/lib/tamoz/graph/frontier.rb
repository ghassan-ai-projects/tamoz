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
        validate_kind!(kind)
        normalized_path = normalize_path(path)
        normalized_input = input.nil? ? nil : StateCodec.new.normalize(input)
        validate_logical_step!(logical_step)

        super(
          node: normalized_node,
          kind:,
          path: normalized_path,
          input: normalized_input,
          activation_checkpoint_id: activation_checkpoint_id&.dup&.freeze,
          logical_step:
        )
      end

      private

      def validate_kind!(kind)
        return if %i[pull push].include?(kind)

        raise ConfigurationError, "frontier kind must be pull or push"
      end

      def normalize_path(path)
        unless path.is_a?(Array) && !path.empty?
          raise ConfigurationError, "frontier path must be a non-empty Array"
        end
        path.map { |part| Identifier.version(part, name: "frontier path part") }.freeze
      end

      def validate_logical_step!(logical_step)
        return if logical_step.is_a?(Integer) && logical_step.positive?

        raise ConfigurationError, "logical_step must be positive"
      end

      public

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
