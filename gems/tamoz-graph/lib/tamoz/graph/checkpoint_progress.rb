# frozen_string_literal: true

module Tamoz
  module Graph
    # Encodes and revives interrupted graph progress.
    class CheckpointProgress
      INTERRUPT_SIZE = 3

      def initialize(values)
        @values = values
        freeze
      end

      def encode_interrupts(interrupts)
        raise CheckpointCorruptionError, 'checkpoint interrupts must be an Array' unless interrupts.is_a?(Array)

        interrupts.sort_by(&:key).map do |interrupt|
          [interrupt.task_id, interrupt.call_index, @values.dump_value(interrupt.descriptor)]
        end
      end

      def decode_interrupts(wire)
        @values.require_array!(wire, nil, 'interrupts')
        previous = nil
        wire.map.with_index do |entry, index|
          @values.require_array!(entry, INTERRUPT_SIZE, "interrupt[#{index}]")
          interrupt = Interrupt.new(
            task_id: @values.bounded_string!(entry.fetch(0), 'interrupt task id'),
            call_index: @values.non_negative_integer!(
              entry.fetch(1),
              'interrupt call index'
            ),
            descriptor: @values.load_value(entry.fetch(2))
          )
          previous = @values.enforce_strictly_ascending!(
            interrupt.key,
            previous,
            'interrupts must have unique sorted identities'
          )
          interrupt
        end.freeze
      end

      def encode_attempts(attempts)
        raise CheckpointCorruptionError, 'checkpoint attempts must be a Hash' unless attempts.is_a?(Hash)

        attempts.keys.sort.map do |task_id|
          [String(task_id), attempts.fetch(task_id)]
        end
      end

      def decode_attempts(wire)
        @values.require_array!(wire, nil, 'attempts')
        previous = nil
        wire.each_with_object({}) do |entry, result|
          @values.require_array!(entry, 2, 'attempt')
          task_id = @values.bounded_string!(entry.fetch(0), 'attempt task id')
          previous = @values.enforce_strictly_ascending!(
            task_id,
            previous,
            'attempt ids must be unique and sorted'
          )
          result[task_id] = @values.non_negative_integer!(entry.fetch(1), 'attempt count')
        end.freeze
      end

      def encode_resume_values(values)
        raise CheckpointCorruptionError, 'resume values must be a Hash' unless values.is_a?(Hash)

        values.keys.sort.map do |task_id|
          indices = values.fetch(task_id)
          validate_resume_indices!(indices)
          [String(task_id), encode_resume_indices(indices)]
        end
      end

      def validate_resume_indices!(indices)
        return if indices.is_a?(Hash)

        raise CheckpointCorruptionError, 'resume task values must be a Hash'
      end

      def encode_resume_indices(indices)
        indices.keys.sort.map do |index|
          [@values.non_negative_integer!(index, 'resume call index'), @values.dump_value(indices.fetch(index))]
        end
      end

      def decode_resume_values(wire)
        @values.require_array!(wire, nil, 'resume values')
        previous_task = nil
        wire.to_h do |task_entry|
          @values.require_array!(task_entry, 2, 'resume task')
          task_id = @values.bounded_string!(task_entry.fetch(0), 'resume task id')
          previous_task = @values.enforce_strictly_ascending!(
            task_id,
            previous_task,
            'resume task ids must be unique and sorted'
          )
          indices = task_entry.fetch(1)
          @values.require_array!(indices, nil, 'resume task values')
          [task_id, decode_resume_indices(indices)]
        end.freeze
      end

      def decode_resume_indices(indices)
        previous_index = nil
        indices.to_h do |index_entry|
          @values.require_array!(index_entry, 2, 'resume call value')
          index = @values.non_negative_integer!(
            index_entry.fetch(0),
            'resume call index'
          )
          previous_index = @values.enforce_strictly_ascending!(
            index,
            previous_index,
            'resume call indices must be unique and sorted'
          )
          [index, @values.load_value(index_entry.fetch(1))]
        end.freeze
      end
    end

    private_constant :CheckpointProgress
  end
end
