# frozen_string_literal: true

module Tamoz
  module Graph
    Outcome = Data.define(
      :task_id,
      :attempt_id,
      :base_checkpoint_id,
      :node,
      :path,
      :update,
      :goto
    ) do
      def initialize(
        task_id:,
        attempt_id:,
        base_checkpoint_id:,
        node:,
        path:,
        update:,
        goto:
      )
        super(
          task_id: String(task_id).dup.freeze,
          attempt_id: String(attempt_id).dup.freeze,
          base_checkpoint_id: String(base_checkpoint_id).dup.freeze,
          node: Identifier.symbol(node, name: "outcome node"),
          path: path.map { |part| String(part).dup.freeze }.freeze,
          update: update.freeze,
          goto: goto&.freeze
        )
      end

      def descriptor
        {
          "task_id" => task_id,
          "attempt_id" => attempt_id,
          "base_checkpoint_id" => base_checkpoint_id,
          "node" => node.to_s,
          "path" => path,
          "update" => update.transform_keys(&:to_s),
          "goto" => goto&.each_with_index&.map do |target, index|
            if target.equal?(Tamoz::END)
              {"kind" => "end"}
            elsif target.is_a?(Send)
              {
                "kind" => "send",
                "node" => target.node.to_s,
                "input" => target.input,
                "key" => target.key || index.to_s
              }
            else
              {"kind" => "pull", "node" => target.to_s}
            end
          end
        }
      end
    end

    private_constant :Outcome
  end
end
