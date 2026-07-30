# frozen_string_literal: true

module Tamoz
  module Graph
    class Planner
      attr_reader :definition_digest

      def initialize(definition_digest:)
        @definition_digest = String(definition_digest).dup.freeze
        freeze
      end

      def tasks(checkpoint)
        checkpoint.frontier.map do |entry|
          activation_id = activation_id(checkpoint.execution_id, entry)
          attempt = checkpoint.attempts.fetch(activation_id, 0) + 1
          Task.new(
            id: activation_id,
            attempt_id: attempt_id(activation_id, attempt, checkpoint.id),
            execution_id: checkpoint.execution_id,
            node: entry.node,
            path: entry.path,
            kind: entry.kind,
            input: entry.input,
            attempt:,
            activation_checkpoint_id: entry.activation_checkpoint_id,
            base_checkpoint_id: checkpoint.id
          )
        end.freeze
      end

      def activation_id(execution_id, entry)
        Canonical.digest(
          {
            "definition_digest" => definition_digest,
            "execution_id" => execution_id,
            "activation_checkpoint_id" => entry.activation_checkpoint_id,
            "logical_step" => entry.logical_step,
            "kind" => entry.kind.to_s,
            "path" => entry.path
          },
          domain: "tamoz.graph.activation"
        )
      end

      def attempt_id(activation_id, attempt, base_checkpoint_id)
        Canonical.digest(
          {
            "activation_id" => activation_id,
            "attempt" => attempt,
            "base_checkpoint_id" => base_checkpoint_id
          },
          domain: "tamoz.graph.attempt"
        )
      end
    end

    private_constant :Planner
  end
end
