# frozen_string_literal: true

module Tamoz
  module Graph
    # Executes graph runs against an already-open checkpoint writer.
    # :reek:FeatureEnvy :reek:DuplicateMethodCall -- this is the writer adapter;
    # checkpoint and graph contracts remain owned by Compiled.
    # :reek:BooleanParameter :reek:ControlParameter :reek:DataClump
    # :reek:LongParameterList :reek:UncommunicativeVariableName :reek:UnusedParameters
    # :reek:UtilityFunction -- the
    # adapter mirrors Compiled's private execution contract at this boundary.
    # :reek:TooManyStatements :reek:RepeatedConditional -- the durable request
    # transition is intentionally kept adjacent to the execution it protects.
    # :reek:MissingSafeMethod -- execution methods enforce state transitions.
    # rubocop:disable Lint/UnusedMethodArgument
    # rubocop:disable Metrics/ParameterLists
    class WriterRunExecutor
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def invoke(
        input,
        thread:,
        namespace:,
        execution_id:,
        concurrency:,
        new_execution:,
        run_context:,
        writer:,
        prepared_state: nil,
        prepared_frontier: nil,
        durable_request_id: nil,
        request_id: nil
      )
        checkpoint = InitialCheckpointBuilder.new(compiled).build(
          input,
          thread:,
          namespace:,
          execution_id:,
          new_execution:,
          writer:,
          prepared_state:,
          prepared_frontier:,
          durable_request_id:
        )
        run_checkpoint(
          checkpoint,
          writer:,
          context: run_context,
          concurrency:,
          durable_request_id:
        )
      end

      def resume(
        answers,
        thread:,
        namespace:,
        request_id:,
        concurrency:,
        context:,
        writer:,
        durable_request_id: nil,
        mark_request_running: true
      )
        checkpoint = compatible_latest(thread, namespace:, writer:)
        raise StaleRequestError, 'latest checkpoint is not paused' unless checkpoint.status == :paused

        resume_values = merge_resume_values(checkpoint, answers, durable_request_id)
        mark_running(writer, durable_request_id, checkpoint) if mark_request_running
        run_checkpoint(
          checkpoint,
          writer:,
          context: build_context(context, request_id:, checkpoint:),
          concurrency:,
          resume_values:,
          durable_request_id:
        )
      end

      def retry_failed(
        thread:,
        namespace:,
        request_id:,
        concurrency:,
        context:,
        writer:,
        durable_request_id: nil,
        mark_request_running: true
      )
        run_existing(
          :failed,
          'latest checkpoint is not failed',
          thread:,
          namespace:,
          request_id:,
          concurrency:,
          context:,
          writer:,
          durable_request_id:,
          mark_request_running:
        )
      end

      def continue(
        thread:,
        namespace:,
        request_id:,
        concurrency:,
        context:,
        writer:,
        durable_request_id: nil,
        mark_request_running: true
      )
        run_existing(
          :running,
          'latest checkpoint has no runnable frontier',
          thread:,
          namespace:,
          request_id:,
          concurrency:,
          context:,
          writer:,
          durable_request_id:,
          mark_request_running:
        )
      end

      private

      attr_reader :compiled

      def run_existing(expected_status, error_message, thread:, namespace:, request_id:, concurrency:, context:,
                       writer:, durable_request_id:, mark_request_running:)
        checkpoint = compatible_latest(thread, namespace:, writer:)
        raise StaleRequestError, error_message unless checkpoint.status == expected_status

        mark_running(writer, durable_request_id, checkpoint) if mark_request_running
        run_checkpoint(
          checkpoint,
          writer:,
          context: build_context(context, request_id:, checkpoint:),
          concurrency:,
          durable_request_id:
        )
      end

      def compatible_latest(thread, namespace:, writer:)
        compiled.__send__(:compatible_latest!, thread, namespace:, writer:)
      end

      def merge_resume_values(checkpoint, answers, durable_request_id)
        compiled.__send__(:merge_resume_values, checkpoint, answers)
      rescue InvalidUpdateError => e
        raise StaleRequestError, e.message if durable_request_id

        raise
      end

      def mark_running(writer, durable_request_id, checkpoint)
        return unless durable_request_id

        writer.mark_request_running(
          request_id: durable_request_id,
          execution_id: checkpoint.execution_id
        )
      end

      def build_context(context, request_id:, checkpoint:)
        compiled.__send__(
          :build_context,
          context,
          thread: checkpoint.thread_id,
          request_id:,
          execution_id: checkpoint.execution_id,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
      end

      def bind_writer_context(context, writer)
        compiled.__send__(:bind_writer_context, context, writer)
      end

      def run_checkpoint(checkpoint, writer:, context:, concurrency:, durable_request_id:, resume_values: nil)
        options = { writer:, context: bind_writer_context(context, writer), concurrency:, durable_request_id: }
        options[:resume_values] = resume_values if resume_values
        Executor.new(compiled).run(checkpoint, **options)
      end
    end
    # rubocop:enable Metrics/ParameterLists
    # rubocop:enable Lint/UnusedMethodArgument
  end
end
