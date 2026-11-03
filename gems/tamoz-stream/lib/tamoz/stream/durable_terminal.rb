# frozen_string_literal: true

module Tamoz
  module Stream
    # What a finished durable request left: its last checkpoint's state and its failure reason.
    module DurableTerminal
      module_function

      # The request's own checkpoint, not the thread's latest: a failed run still witnesses its receipts.
      def state(durable_runner, thread_id:, namespace:, result:)
        return {} unless result.checkpoint_id

        durable_runner.compiled.checkpointer.find(
          thread_id:, namespace:, checkpoint_id: result.checkpoint_id
        ).state.to_h
      end

      def reason_code(result)
        return nil if result.nil? || result.status != :failed

        terminal_error = result.respond_to?(:terminal_error) ? result.terminal_error : nil
        return nil unless terminal_error.is_a?(Hash)

        terminal_error.fetch('category', terminal_error.fetch('graph_status', nil))
      end
    end
  end
end
