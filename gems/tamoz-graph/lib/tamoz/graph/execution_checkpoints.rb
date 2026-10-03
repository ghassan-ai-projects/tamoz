# frozen_string_literal: true

module Tamoz
  module Graph
    # Persists graph execution barriers and terminal request transitions.
    class ExecutionCheckpoints
      def initialize(compiled, events)
        @compiled = compiled
        @events = events
      end

      def append_noncommitting(
        checkpoint,
        writer:,
        status:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        failure:,
        request_transition:
      )
        compiled.append_checkpoint(
          writer:,
          thread: checkpoint.thread_id,
          namespace: checkpoint.namespace,
          expected_base_id: checkpoint.id,
          mode: :advance,
          execution_id: checkpoint.execution_id,
          state: checkpoint.state,
          status:,
          logical_step: checkpoint.logical_step,
          frontier: checkpoint.frontier,
          pending:,
          interrupts:,
          resume_values:,
          attempts:,
          failure:,
          total_tasks:,
          request_transition:
        )
      end

      def terminal_request_transition(
        writer,
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        return nil unless request_id
        unless writer.respond_to?(:request_transition)
          raise ConfigurationError,
                'durable request execution requires a request-capable writer'
        end

        writer.request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status:,
          retryable:
        )
      end

      def append_failed_checkpoint(
        checkpoint,
        writer:,
        context:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        errors:,
        request_id:
      )
        failed = append_noncommitting(
          checkpoint,
          writer:,
          status: :failed,
          pending:,
          interrupts:,
          attempts:,
          resume_values:,
          total_tasks:,
          failure: failure_descriptors(errors),
          request_transition: failed_request_transition(writer, checkpoint, request_id)
        )
        @events.emit_errors(context, errors)
        @events.emit_checkpoint(context, failed)
        failed
      end

      def append_paused_checkpoint(
        checkpoint,
        writer:,
        context:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        request_id:
      )
        paused = append_noncommitting(
          checkpoint,
          writer:,
          status: :paused,
          pending:,
          interrupts:,
          attempts:,
          resume_values:,
          total_tasks:,
          failure: nil,
          request_transition: paused_request_transition(writer, checkpoint, request_id)
        )
        @events.emit_interrupts(context, interrupts)
        @events.emit_checkpoint(context, paused)
        paused
      end

      def failure_descriptors(errors)
        errors.map do |error|
          {
            'graph' => error.graph_name,
            'node' => error.node,
            'task_id' => error.task_id,
            'attempt_id' => error.attempt_id,
            'error_class' => @events.stable_error_class(error.original),
            'safe_message' => error.safe_message
          }.freeze
        end.freeze
      end

      private

      attr_reader :compiled

      def failed_request_transition(writer, checkpoint, request_id)
        terminal_request_transition(
          writer, request_id:, execution_id: checkpoint.execution_id,
                  action: :failed, graph_status: :failed, retryable: false
        )
      end

      def paused_request_transition(writer, checkpoint, request_id)
        terminal_request_transition(
          writer, request_id:, execution_id: checkpoint.execution_id,
                  action: :completed, graph_status: :paused
        )
      end
    end

    private_constant :ExecutionCheckpoints
  end
end
