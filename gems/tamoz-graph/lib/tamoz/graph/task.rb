# frozen_string_literal: true

module Tamoz
  module Graph
    Task = Data.define(
      :id,
      :attempt_id,
      :execution_id,
      :node,
      :path,
      :kind,
      :input,
      :attempt,
      :activation_checkpoint_id,
      :base_checkpoint_id
    ) do
      def initialize(**attributes)
        path = attributes.fetch(:path)
        super(
          **attributes,
          id: String(attributes.fetch(:id)).dup.freeze,
          attempt_id: String(attributes.fetch(:attempt_id)).dup.freeze,
          execution_id: String(attributes.fetch(:execution_id)).dup.freeze,
          node: Identifier.symbol(attributes.fetch(:node), name: "task node"),
          path: path.map { |part| String(part).dup.freeze }.freeze,
          kind: attributes.fetch(:kind),
          input: attributes.fetch(:input),
          activation_checkpoint_id: String(
            attributes.fetch(:activation_checkpoint_id)
          ).dup.freeze,
          base_checkpoint_id: String(attributes.fetch(:base_checkpoint_id)).dup.freeze
        )
      end

      def descriptor
        {
          "id" => id,
          "attempt_id" => attempt_id,
          "execution_id" => execution_id,
          "node" => node.to_s,
          "path" => path,
          "kind" => kind.to_s,
          "attempt" => attempt,
          "activation_checkpoint_id" => activation_checkpoint_id,
          "base_checkpoint_id" => base_checkpoint_id
        }
      end
    end
  end
end
