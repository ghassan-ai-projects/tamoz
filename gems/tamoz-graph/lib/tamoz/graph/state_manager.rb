# frozen_string_literal: true

module Tamoz
  module Graph
    class StateManager
      attr_reader :channels, :codec

      def initialize(channels:, codec:)
        @channels = channels
        @codec = codec
        freeze
      end

      def initial(input, remaining_steps:)
        state = channels.to_h do |name, channel|
          value = if channel.managed?
                    remaining_steps
                  else
                    channel.default(codec)
                  end
          [name, value]
        end
        writes = normalize_update(input, allow_managed: false)
        apply_writes(state, [{"task_id" => "input", "update" => writes}], remaining_steps:)
      end

      def normalize_update(value, allow_managed: false)
        normalized = codec.normalize(value)
        raise InvalidUpdateError, "node update must be a Hash" unless normalized.is_a?(Hash)

        result = {}
        normalized.each do |raw_name, entry|
          name = resolve_channel(raw_name)
          channel = channels.fetch(name)
          if channel.managed? && !allow_managed
            raise InvalidUpdateError, "managed channel #{name} is read-only"
          end
          raise InvalidUpdateError, "duplicate update channel #{name}" if result.key?(name)

          result[name] = entry
        end
        result.freeze
      end

      def task_input(value)
        return value unless value.is_a?(Hash)

        value.to_h do |raw_name, entry|
          [resolve_channel(raw_name), entry]
        end.freeze
      end

      def apply_outcomes(state, outcomes, remaining_steps:)
        records = outcomes.map do |outcome|
          {"task_id" => outcome.task_id, "update" => outcome.update}
        end
        apply_writes(state, records, remaining_steps:)
      end

      def state_bytes(state)
        codec.dump(state)
      end

      private

      def apply_writes(state, records, remaining_steps:)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        writers = Hash.new { |hash, key| hash[key] = [] }
        records.each do |record|
          record.fetch("update").each do |name, value|
            grouped[name] << value
            writers[name] << record.fetch("task_id")
          end
        end

        candidate = state.dup
        grouped.each do |name, values|
          channel = channels.fetch(name)
          if channel.reducer
            begin
              candidate[name] = channel.reducer.call(candidate.fetch(name), values.freeze)
            rescue InvalidUpdateError
              raise
            rescue StandardError => error
              raise InvalidUpdateError,
                    "reducer #{channel.reducer.name} failed for #{name}: #{error.class}"
            end
          elsif values.length == 1
            candidate[name] = values.first
          else
            raise InvalidUpdateError,
                  "conflicting writes to #{name} from #{writers.fetch(name).sort.join(", ")}"
          end
        end
        channels.each do |name, channel|
          candidate[name] = remaining_steps if channel.managed?
        end
        normalize_state(candidate)
      end

      def normalize_state(state)
        normalized = channels.to_h do |name, _channel|
          [name, codec.normalize(state.fetch(name))]
        end.freeze
        codec.dump(normalized)
        normalized
      end

      def resolve_channel(raw_name)
        text = String(raw_name)
        matches = channels.keys.select { |name| name.to_s == text }
        raise InvalidUpdateError, "unknown state channel #{text.inspect}" if matches.empty?

        matches.first
      end
    end

    private_constant :StateManager
  end
end
