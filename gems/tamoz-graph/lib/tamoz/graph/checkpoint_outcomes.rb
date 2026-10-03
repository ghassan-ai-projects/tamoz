# frozen_string_literal: true

module Tamoz
  module Graph
    # Encodes and revives persisted task outcomes.
    class CheckpointOutcomes
      OUTCOME_FORMAT = 'tamoz.graph.outcome'
      ROUTES_FORMAT = 'tamoz.graph.routes'
      OUTCOME_SIZE = 7

      def initialize(values, routes)
        @values = values
        @routes = routes
        freeze
      end

      def dump_outcome(outcome)
        wire = [
          OUTCOME_FORMAT,
          1,
          outcome.task_id,
          outcome.attempt_id,
          outcome.base_checkpoint_id,
          outcome.node.to_s,
          outcome.path,
          @values.dump_value(outcome.update),
          @routes.encode_goto(outcome.goto)
        ]
        JSON.generate(wire).freeze
      rescue JSON::GeneratorError => e
        raise CheckpointCorruptionError.new(
          'task outcome cannot be encoded'
        ), cause: e
      end

      def dump_outcome_writes(outcome)
        writes = outcome.update.keys.sort_by(&:to_s).map.with_index do |channel, index|
          {
            'write_index' => index,
            'kind' => 'channel',
            'channel' => channel.to_s,
            'payload' => @values.dump_value(outcome.update.fetch(channel))
          }.freeze
        end
        route_payload = JSON.generate(
          [ROUTES_FORMAT, 1, @routes.encode_goto(outcome.goto)]
        ).freeze
        writes << {
          'write_index' => writes.length,
          'kind' => 'routes',
          'channel' => nil,
          'payload' => route_payload
        }.freeze
        writes.freeze
      end

      def load_outcome(metadata:, writes:)
        unless metadata.is_a?(Hash) && writes.is_a?(Array) && !writes.empty?
          raise CheckpointCorruptionError, 'pending outcome rows are incomplete'
        end

        ordered = outcome_writes_in_order!(writes)

        update, routes = decode_outcome_writes(ordered)
        outcome_from_metadata(metadata, update, routes)
      rescue KeyError => e
        raise CheckpointCorruptionError.new(
          "pending outcome row is missing #{e.key.inspect}"
        ), cause: e
      end

      def decode_outcome_writes(ordered)
        update = {}
        routes = nil
        routes_seen = false
        ordered.each do |write|
          case write.fetch('kind')
          when 'channel'
            decode_pending_channel_write(write, update, routes_seen)
          when 'routes'
            routes = decode_pending_routes_write(write, routes_seen)
            routes_seen = true
          else
            raise CheckpointCorruptionError, 'pending write kind is invalid'
          end
        end
        unless ordered.last.fetch('kind') == 'routes'
          raise CheckpointCorruptionError, 'pending outcome is missing routes'
        end

        [update.freeze, routes]
      end

      def outcome_from_metadata(metadata, update, routes)
        Outcome.new(
          task_id: @values.bounded_string!(metadata.fetch('task_id'), 'pending task id'),
          attempt_id: @values.bounded_string!(
            metadata.fetch('attempt_id'),
            'pending attempt id'
          ),
          base_checkpoint_id: @values.bounded_string!(
            metadata.fetch('base_checkpoint_id'),
            'pending base checkpoint id'
          ),
          node: @values.node!(metadata.fetch('node'), 'pending node'),
          path: decode_path_bytes(metadata.fetch('path')),
          update: update.freeze,
          goto: routes
        )
      end

      def decode_path_bytes(bytes)
        wire = @values.parse_canonical_json(bytes, 'pending path')
        @values.string_array!(wire, 'pending path')
      end

      def outcome_writes_in_order!(writes)
        ordered = writes.sort_by { |write| write.fetch('write_index') }
        unless ordered.map { |write| write.fetch('write_index') } ==
               (0...ordered.length).to_a
          raise CheckpointCorruptionError,
                'pending outcome write indices are not contiguous'
        end

        ordered
      end

      def decode_pending_channel_write(write, update, routes_seen)
        if routes_seen
          raise CheckpointCorruptionError,
                'pending channel write appears after routes'
        end
        channel = @values.channel!(write.fetch('channel'), 'pending write channel')
        if update.key?(channel)
          raise CheckpointCorruptionError,
                "pending outcome repeats channel #{channel}"
        end
        update[channel] = @values.load_value(write.fetch('payload'))
      end

      def decode_pending_routes_write(write, routes_seen)
        raise CheckpointCorruptionError, 'pending routes write is invalid' if routes_seen || write.fetch('channel')

        route_wire = @values.parse_canonical_json(
          write.fetch('payload'),
          'pending routes'
        )
        @values.require_array!(route_wire, 3, 'pending routes')
        unless route_wire.fetch(0) == ROUTES_FORMAT && route_wire.fetch(1) == 1
          raise CheckpointVersionError, 'pending routes format is unsupported'
        end

        @routes.decode_goto(route_wire.fetch(2))
      end

      def encode_pending(pending)
        raise CheckpointCorruptionError, 'checkpoint pending outcomes must be a Hash' unless pending.is_a?(Hash)

        pending.keys.sort.map do |task_id|
          outcome = pending.fetch(task_id)
          unless outcome.task_id == task_id
            raise CheckpointCorruptionError, 'pending outcome task identity is mismatched'
          end

          [
            outcome.task_id,
            outcome.attempt_id,
            outcome.base_checkpoint_id,
            outcome.node.to_s,
            outcome.path,
            @values.dump_value(outcome.update),
            @routes.encode_goto(outcome.goto)
          ]
        end
      end

      def decode_pending(wire)
        @values.require_array!(wire, nil, 'pending outcomes')
        previous = nil
        wire.each_with_object({}) do |entry, result|
          @values.require_array!(entry, OUTCOME_SIZE, 'pending outcome')
          task_id = @values.bounded_string!(entry.fetch(0), 'pending task id')
          previous = @values.enforce_strictly_ascending!(
            task_id,
            previous,
            'pending outcomes must have unique sorted task ids'
          )
          result[task_id] = decode_pending_outcome(entry, task_id)
        end.freeze
      end

      def decode_pending_outcome(entry, task_id)
        Outcome.new(
          task_id:,
          attempt_id: @values.bounded_string!(entry.fetch(1), 'pending attempt id'),
          base_checkpoint_id: @values.bounded_string!(
            entry.fetch(2),
            'pending base checkpoint id'
          ),
          node: @values.node!(entry.fetch(3), 'pending node'),
          path: @values.string_array!(entry.fetch(4), 'pending path'),
          update: @values.decode_update(entry.fetch(5)),
          goto: @routes.decode_goto(entry.fetch(6))
        )
      end
    end

    private_constant :CheckpointOutcomes
  end
end
