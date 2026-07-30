# frozen_string_literal: true

module Tamoz
  module Graph
    Interrupt = Data.define(:task_id, :call_index, :descriptor) do
      def initialize(task_id:, call_index:, descriptor:)
        unless call_index.is_a?(Integer) && !call_index.negative?
          raise ConfigurationError, "interrupt call_index must be non-negative"
        end
        super(
          task_id: String(task_id).dup.freeze,
          call_index:,
          descriptor: StateCodec.new.normalize(descriptor)
        )
      end

      def key
        [task_id, call_index].freeze
      end
    end

    class InterruptCursor
      attr_reader :task_id

      def initialize(task_id:, resume_values:)
        @task_id = String(task_id).dup.freeze
        @resume_values = resume_values
        @call_index = 0
      end

      def call(descriptor)
        index = @call_index
        @call_index += 1
        return @resume_values.fetch(index) if @resume_values.key?(index)

        normalized = StateCodec.new.normalize(descriptor)
        throw(
          :tamoz_interrupt,
          {
            "task_id" => task_id,
            "call_index" => index,
            "descriptor" => normalized
          }
        )
      end
    end

    private_constant :InterruptCursor
  end

  def self.interrupt(descriptor, context)
    cursor = context&.interrupts
    unless cursor&.respond_to?(:call)
      raise ConfigurationError, "interrupt requires a graph task Context"
    end

    cursor.call(descriptor)
  end
end
