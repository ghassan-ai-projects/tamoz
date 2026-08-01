# frozen_string_literal: true

module Tamoz
  module Graph
    class StreamEmitter
      PROJECTIONS = {
        runs: %i[run_start run_end],
        tasks: %i[task_start task_end],
        updates: %i[node_update],
        messages: %i[message_chunk],
        interrupts: %i[interrupt],
        checkpoints: %i[checkpoint],
        errors: %i[error]
      }.freeze
      ALWAYS = %i[run_start run_end error].freeze

      def self.validate_mode!(mode)
        types_for(mode)
        true
      end

      def initialize(sink:, mode:)
        @sink = sink
        @types = self.class.__send__(:types_for, mode)
        freeze
      end

      def emit(type, namespace, data = {}, run_id: nil, task_id: nil)
        return false unless @types.include?(type.to_sym)

        @sink.emit(type, namespace, data, run_id:, task_id:)
      rescue StreamClosedError
        raise unless @sink.cancellation.cancelled?

        false
      end

      private

      def self.types_for(mode)
        return StreamPartContract::CORE_TYPES if mode == :all

        selections = mode.is_a?(Array) ? mode : [mode]
        if selections.empty? || selections.any? { |entry| !PROJECTIONS.key?(entry) }
          raise ConfigurationError,
                "stream mode must be :all or selections from #{PROJECTIONS.keys.inspect}"
        end

        (ALWAYS + selections.flat_map { |entry| PROJECTIONS.fetch(entry) }).uniq.freeze
      end
      private_class_method :types_for

      private_constant :ALWAYS, :PROJECTIONS
    end
  end
end
