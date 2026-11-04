# frozen_string_literal: true

module Tamoz
  module Graph
    # Persists graph execution barriers and terminal request transitions.
    class ExecutionCheckpoints
      def initialize(compiled, events)
        @compiled = compiled
        @events = events
      end

      def append_noncommitting(checkpoint, writer:, barrier:, failure:, request_transition:)
        compiled.append_checkpoint(
          writer:,
          thread: checkpoint.thread_id,
          namespace: checkpoint.namespace,
          expected_base_id: checkpoint.id,
          mode: :advance,
          execution_id: checkpoint.execution_id,
          state: checkpoint.state,
          logical_step: checkpoint.logical_step,
          frontier: checkpoint.frontier,
          **barrier,
          failure:,
          request_transition:
        )
      end

      def terminal_request_transition(execution, checkpoint, action:, graph_status:, retryable: nil)
        return nil unless execution.request_id

        writer = execution.writer
        unless writer.respond_to?(:request_transition)
          raise ConfigurationError,
                'durable request execution requires a request-capable writer'
        end

        writer.request_transition(
          request_id: execution.request_id,
          execution_id: checkpoint.execution_id,
          action:,
          graph_status:,
          retryable:
        )
      end

      def append_failed_checkpoint(checkpoint, step, execution, errors:)
        failed = append_noncommitting(
          checkpoint,
          writer: execution.writer,
          barrier: barrier(:failed, step, execution),
          failure: failure_descriptors(errors),
          request_transition: terminal_request_transition(
            execution, checkpoint, action: :failed, graph_status: :failed, retryable: false
          )
        )
        @events.emit_errors(execution.context, errors)
        @events.emit_checkpoint(execution.context, failed)
        failed
      end

      def append_paused_checkpoint(checkpoint, step, execution)
        paused = append_noncommitting(
          checkpoint,
          writer: execution.writer,
          barrier: barrier(:paused, step, execution),
          failure: nil,
          request_transition: terminal_request_transition(
            execution, checkpoint, action: :completed, graph_status: :paused
          )
        )
        @events.emit_interrupts(execution.context, step.interruptions)
        @events.emit_checkpoint(execution.context, paused)
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

      def barrier(status, step, execution)
        { status:, pending: step.successes, interrupts: step.interruptions, attempts: step.attempts,
          resume_values: execution.resume_values, total_tasks: step.total_tasks }
      end
    end

    private_constant :ExecutionCheckpoints
  end
end
