# frozen_string_literal: true

module Tamoz
  module Graph
    # Opens a writer and routes public graph operations to writer-backed execution.
    # :reek:FeatureEnvy :reek:DataClump :reek:LongParameterList
    # :reek:ControlParameter :reek:TooManyStatements -- this adapter preserves
    # the public operation-to-writer protocol in one place.
    # rubocop:disable Metrics/ParameterLists
    class RunCoordinator
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def invoke(
        input,
        thread:,
        namespace:,
        request_id:,
        execution_id:,
        concurrency:,
        new_execution:,
        context:,
        prepared_state: nil,
        prepared_frontier: nil
      )
        validate_invocation(new_execution, concurrency)
        run_context = invocation_context(context, thread:, request_id:, execution_id:)
        open_writer(thread, namespace) do |writer|
          compiled.__send__(
            :invoke_with_writer,
            input,
            thread:,
            namespace:,
            request_id:,
            execution_id:,
            concurrency:,
            new_execution:,
            run_context:,
            writer:,
            prepared_state:,
            prepared_frontier:
          )
        end
      end

      def resume(answers, thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          compiled.__send__(
            :resume_with_writer,
            answers,
            thread:,
            namespace:,
            request_id:,
            concurrency:,
            context:,
            writer:
          )
        end
      end

      def retry_failed(thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          compiled.__send__(
            :retry_failed_with_writer,
            thread:,
            namespace:,
            request_id:,
            concurrency:,
            context:,
            writer:
          )
        end
      end

      def continue(thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          compiled.__send__(
            :continue_with_writer,
            thread:,
            namespace:,
            request_id:,
            concurrency:,
            context:,
            writer:
          )
        end
      end

      private

      attr_reader :compiled

      def validate_invocation(new_execution, concurrency)
        raise ConfigurationError, 'new_execution must be true or false' unless [true, false].include?(new_execution)

        compiled.__send__(:validate_concurrency!, concurrency)
      end

      def invocation_context(context, thread:, request_id:, execution_id:)
        build_context(
          context,
          thread:,
          request_id:,
          execution_id:,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
      end

      def build_context(base, **attributes)
        compiled.__send__(:build_context, base, **attributes)
      end

      def open_writer(thread, namespace, &)
        compiled.__send__(:open_writer, thread, namespace, &)
      end
    end
    # rubocop:enable Metrics/ParameterLists
  end
end
