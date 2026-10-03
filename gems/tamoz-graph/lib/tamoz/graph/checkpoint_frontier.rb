# frozen_string_literal: true

module Tamoz
  module Graph
    # Encodes and revives the scheduled graph frontier.
    class CheckpointFrontier
      FRONTIER_SIZE = 6
      KINDS = %w[pull push].freeze

      def initialize(values)
        @values = values
        freeze
      end

      def encode_frontier(frontier)
        raise CheckpointCorruptionError, 'checkpoint frontier must be an Array' unless frontier.is_a?(Array)

        frontier.map do |entry|
          [
            entry.node.to_s,
            entry.kind.to_s,
            entry.path,
            entry.input.nil? ? nil : @values.dump_value(entry.input),
            entry.activation_checkpoint_id,
            entry.logical_step
          ]
        end
      end

      def decode_frontier(wire, strict: true)
        @values.require_array!(wire, nil, 'frontier')
        wire.map.with_index do |entry, index|
          decode_entry(entry, index, strict:)
        end.freeze
      end

      def decode_entry(entry, index, strict:)
        @values.require_array!(entry, FRONTIER_SIZE, "frontier[#{index}]")
        node = if strict
                 @values.node!(entry.fetch(0), "frontier[#{index}] node")
               else
                 @values.bounded_string!(entry.fetch(0), "frontier[#{index}] node")
               end
        kind = entry.fetch(1)
        unless KINDS.include?(kind)
          raise CheckpointCorruptionError,
                "frontier[#{index}] kind must be pull or push"
        end
        decode_entry_fields(entry, index, node, kind)
      end

      def decode_entry_fields(entry, index, node, kind)
        path = @values.string_array!(entry.fetch(2), "frontier[#{index}] path")
        input = entry.fetch(3).nil? ? nil : @values.load_value(entry.fetch(3))
        activation_checkpoint_id = @values.optional_string!(
          entry.fetch(4),
          "frontier[#{index}] activation checkpoint id"
        )
        logical_step = @values.positive_integer!(
          entry.fetch(5),
          "frontier[#{index}] logical step"
        )
        Frontier.new(
          node:,
          kind: kind == 'pull' ? :pull : :push,
          path:,
          input:,
          activation_checkpoint_id:,
          logical_step:
        )
      end
    end

    private_constant :CheckpointFrontier
  end
end
