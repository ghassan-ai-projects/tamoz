# frozen_string_literal: true

module Tamoz
  module Graph
    # Dispatches claimed durable requests to the compiled graph's execution paths.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy -- this is an adapter: request
    # fields are deliberately translated into the compiled graph's private execution
    # contract, and repeating those fields would hide the operation mapping.
    # :reek:TooManyStatements -- the dispatch case is the durable request protocol;
    # splitting its operation branches would scatter the protocol vocabulary.
    # :reek:MissingSafeMethod -- validation raises typed boundary errors; a predicate
    # would allow invalid requests or redirects to continue toward execution.
    class DurableRequestExecutor
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def execute(execution)
        request = execution.request
        validate_request!(request)
        compiled.__send__(:validate_concurrency!, execution.concurrency)
        dispatch(execution)
      end

      private

      attr_reader :compiled

      def dispatch(execution)
        case execution.request.operation
        when :turn then execute_turn(execution)
        when :resume then execute_resume(execution)
        when :retry then execute_retry(execution)
        when :continue then execute_continue(execution)
        when :fork then execute_fork(execution)
        when :redirect then execute_redirect(execution)
        else
          raise ConfigurationError,
                "durable request operation #{execution.request.operation.inspect} is not executable yet"
        end
      end

      def validate_request!(request)
        return if request.is_a?(RequestRecord) && request.thread_id && request.execution_id &&
                  %i[claimed running redirecting].include?(request.status)

        raise ConfigurationError, 'durable request is not executable'
      end

      def execute_turn(execution)
        return execute_new(execution) if execution.request.status == :claimed

        continue_after_claim(execution)
      end

      def execute_resume(execution)
        request = execution.request
        if request.status == :running && latest_status(execution) == :running
          continue_after_claim(execution)
        else
          compiled.__send__(
            :resume_with_writer,
            request.payload,
            thread: request.thread_id,
            namespace: request.namespace,
            request_id: request.request_id,
            concurrency: execution.concurrency,
            context: execution.context,
            writer: execution.writer,
            durable_request_id: request.request_id,
            mark_request_running: request.status == :claimed
          )
        end
      end

      def execute_retry(execution)
        request = execution.request
        compiled.__send__(
          :retry_failed_with_writer,
          thread: request.thread_id,
          namespace: request.namespace,
          request_id: request.request_id,
          concurrency: execution.concurrency,
          context: execution.context,
          writer: execution.writer,
          durable_request_id: request.request_id,
          mark_request_running: request.status == :claimed
        )
      end

      def execute_continue(execution)
        request = execution.request
        compiled.__send__(
          :continue_with_writer,
          thread: request.thread_id,
          namespace: request.namespace,
          request_id: request.request_id,
          concurrency: execution.concurrency,
          context: execution.context,
          writer: execution.writer,
          durable_request_id: request.request_id,
          mark_request_running: request.status == :claimed
        )
      end

      def continue_after_claim(execution)
        request = execution.request
        compiled.__send__(
          :continue_with_writer,
          thread: request.thread_id,
          namespace: request.namespace,
          request_id: request.request_id,
          concurrency: execution.concurrency,
          context: execution.context,
          writer: execution.writer,
          durable_request_id: request.request_id,
          mark_request_running: false
        )
      end

      def execute_fork(execution)
        compiled.__send__(
          :fork_with_writer,
          execution.request,
          writer: execution.writer,
          concurrency: execution.concurrency,
          context: execution.context
        )
      end

      def execute_redirect(execution)
        validate_redirect!(execution)
        return continue_after_claim(execution) if execution.request.status == :running

        execute_new(execution)
      end

      def execute_new(execution)
        request = execution.request
        compiled.__send__(
          :invoke_with_writer,
          request.payload,
          thread: request.thread_id,
          namespace: request.namespace,
          request_id: request.request_id,
          execution_id: request.execution_id,
          concurrency: execution.concurrency,
          new_execution: true,
          run_context: request_context(execution),
          writer: execution.writer,
          durable_request_id: request.request_id
        )
      end

      def request_context(execution)
        request = execution.request
        compiled.__send__(
          :build_context,
          execution.context,
          thread: request.thread_id,
          request_id: request.request_id,
          execution_id: request.execution_id,
          cancellation: execution.context&.cancellation || CancellationToken.new,
          emitter: execution.context&.emitter || Emitter::Null::INSTANCE
        )
      end

      def latest_status(execution)
        compiled.__send__(:latest_status, execution.request, writer: execution.writer)
      end

      def validate_redirect!(execution)
        request = execution.request
        writer = execution.writer
        return if request.target_execution_id && request.cancellation_generation &&
                  writer.redirect_ready?(target_execution_id: request.target_execution_id)

        raise CheckpointConflictError,
              'redirect is waiting for target effects to become terminal'
      end
    end
  end
end
