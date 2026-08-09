# frozen_string_literal: true

module Tamoz
  module Graph
    # Owns the public invoke, stream, resume, retry, and continue lifecycle.
    # :reek:FeatureEnvy :reek:DataClump :reek:LongParameterList
    # :reek:ControlParameter :reek:TooManyStatements -- this is the public graph
    # surface adapter; operation semantics remain grouped by lifecycle.
    # :reek:DuplicateMethodCall :reek:UncommunicativeVariableName :reek:UtilityFunction -- the stream event sequence
    # deliberately repeats the stream context and graph identity at its boundaries.
    # rubocop:disable Metrics/ParameterLists
    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    class LifecycleExecutor
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def invoke(input = {}, thread:, request_id:, execution_id:, concurrency:, new_execution:, context:)
        compiled.__send__(:ensure_ephemeral_public!)
        run_context = compiled.__send__(
          :build_context,
          context,
          thread:,
          request_id:,
          execution_id:,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        compiled.__send__(
          :invoke_at,
          input,
          thread:,
          namespace: [],
          request_id:,
          execution_id:,
          concurrency:,
          new_execution:,
          context: run_context,
          prepared_state: compiled.state_manager.initial(input || {}, remaining_steps: compiled.limits.max_steps),
          prepared_frontier: compiled.route_planner.initial_frontier
        )
      end

      def stream(
        input = {},
        thread:,
        request_id:,
        execution_id:,
        concurrency:,
        new_execution:,
        context:,
        mode:,
        capacity:,
        join_grace:
      )
        StreamEmitter.validate_mode!(mode)
        sink, stream_context, emitter, run_id = stream_parts(
          thread,
          request_id,
          execution_id,
          context,
          mode,
          capacity
        )
        EventStream.new(sink:, join_grace:) do
          emitter.emit(:run_start, stream_context.namespace, {
            'graph' => compiled.name,
            'execution_id' => execution_id
          }, run_id:)
          result = compiled.invoke(
            input,
            thread:,
            request_id:,
            execution_id:,
            concurrency:,
            new_execution:,
            context: stream_context
          )
          emitter.emit(:run_end, stream_context.namespace, {
            'graph' => compiled.name,
            'status' => result.status.to_s
          }, run_id:)
          result
        rescue StandardError => e
          emitter.emit(:error, stream_context.namespace, compiled.__send__(:stream_error_data, e), run_id:)
          raise
        end
      rescue StandardError
        sink&.finish
        raise
      end

      def resume(answers, thread:, request_id:, concurrency:, context:)
        compiled.__send__(:ensure_ephemeral_public!)
        compiled.__send__(:resume_at, answers, thread:, namespace: [], request_id:, concurrency:, context:)
      end

      def retry_failed(thread:, request_id:, concurrency:, context:)
        compiled.__send__(:ensure_ephemeral_public!)
        compiled.__send__(:retry_failed_at, thread:, namespace: [], request_id:, concurrency:, context:)
      end

      def continue(thread:, request_id:, concurrency:, context:)
        compiled.__send__(:ensure_ephemeral_public!)
        compiled.__send__(:continue_at, thread:, namespace: [], request_id:, concurrency:, context:)
      end

      private

      attr_reader :compiled

      def stream_parts(thread, request_id, execution_id, context, mode, capacity)
        cancellation = context&.cancellation || CancellationToken.new
        run_id = context&.run_id || SecureRandom.uuid
        sink = StreamSink.new(
          capacity:,
          cancellation:,
          clock: context&.clock || Clock.monotonic,
          run_id:
        )
        emitter = StreamEmitter.new(sink:, mode:)
        stream_context = if context
                           context.with(
                             execution_id:,
                             request_id:,
                             thread_id: thread,
                             cancellation:,
                             emitter:
                           )
                         else
                           Context.new(
                             run_id:,
                             execution_id:,
                             request_id:,
                             thread_id: thread,
                             cancellation:,
                             emitter:
                           )
                         end
        [sink, stream_context, emitter, run_id]
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/ParameterLists
  end
end
