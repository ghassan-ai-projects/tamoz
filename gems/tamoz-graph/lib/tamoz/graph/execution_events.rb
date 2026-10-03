# frozen_string_literal: true

module Tamoz
  module Graph
    # Emits graph execution observations.
    class ExecutionEvents
      def initialize(compiled)
        @compiled = compiled
      end

      def emit_update(context, outcome)
        context.emit(
          :node_update,
          {
            'graph' => compiled.name,
            'node' => outcome.node.to_s,
            'channels' => outcome.update.keys.map(&:to_s).sort
          }
        )
      end

      def emit_interrupts(context, interrupts)
        interrupts.each do |interrupt|
          context.emit(
            :interrupt,
            {
              'graph' => compiled.name,
              'task_id' => interrupt.task_id,
              'call_index' => interrupt.call_index
            }
          )
        end
      end

      def emit_checkpoint(context, checkpoint)
        context.emit(
          :checkpoint,
          {
            'graph' => compiled.name,
            'checkpoint_id' => checkpoint.id,
            'sequence' => checkpoint.sequence,
            'status' => checkpoint.status.to_s
          }
        )
      end

      def emit_errors(context, errors)
        errors.each do |error|
          context.emit(
            :error,
            {
              'graph' => compiled.name,
              'node' => error.node,
              'task_id' => error.task_id,
              'error_class' => stable_error_class(error.original),
              'category' => error.category,
              'safe_message' => error.safe_message
            }
          )
        end
      end

      def stable_error_class(error)
        name = error.class.name.to_s
        name.empty? ? 'AnonymousError' : name
      end

      private

      attr_reader :compiled
    end

    private_constant :ExecutionEvents
  end
end
