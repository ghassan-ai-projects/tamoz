# frozen_string_literal: true

require "securerandom"

module Tamoz
  module Graph
    class Compiled
      attr_reader :definition, :definition_digest, :codec, :checkpointer, :limits,
                  :checkpoint_codec

      def initialize(
        definition:,
        definition_digest:,
        codec:,
        checkpointer:,
        limits:,
        pools: nil
      )
        @definition = definition
        @definition_digest = String(definition_digest).dup.freeze
        @codec = codec
        @limits = limits
        @state_manager = StateManager.new(channels: definition.channels, codec:)
        @resume_answers = ResumeAnswers.new(codec:)
        @checkpoint_codec = CheckpointCodec.new(
          definition:,
          definition_digest: @definition_digest,
          state_codec: codec
        )
        @checkpointer = resolve_checkpointer(checkpointer)
        @planner = Planner.new(definition_digest:)
        @route_planner = RoutePlanner.new(definition:)
        @pools = build_pools(pools)
        freeze
      end

      def name = definition.name
      def version = definition.version
      def channels = definition.channels
      def nodes = definition.nodes

      def invoke(
        input = {},
        thread:,
        request_id:,
        execution_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        new_execution: false,
        context: nil
      )
        LifecycleExecutor.new(self).invoke(
          input,
          thread:,
          request_id:,
          execution_id:,
          concurrency:,
          new_execution:,
          context:
        )
      end

      def stream(
        input = {},
        thread:,
        request_id:,
        execution_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        new_execution: false,
        context: nil,
        mode: :all,
        capacity: Tamoz.configuration.stream_buffer,
        join_grace: 1.0
      )
        LifecycleExecutor.new(self).stream(
          input,
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
      end

      def resume(
        answers,
        thread:,
        request_id:,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        LifecycleExecutor.new(self).resume(
          answers,
          thread:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def retry_failed(
        thread:,
        request_id:,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        LifecycleExecutor.new(self).retry_failed(
          thread:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def continue(
        thread:,
        request_id:,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        LifecycleExecutor.new(self).continue(
          thread:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def call(input, context)
        runtime = context&.graph_runtime
        unless runtime&.respond_to?(:call)
          raise ConfigurationError, "compiled graph invocation requires a parent graph task Context"
        end
        runtime.call(self, input, context)
      end

      def state(thread:, checkpoint_id: nil, namespace: [])
        StateOperations.new(self).state(thread:, checkpoint_id:, namespace:)
      end

      def history(thread:, namespace: [], limit: limits.history_limit)
        StateOperations.new(self).history(thread:, namespace:, limit:)
      end

      def durable_runner = DurableRunner.new(self)

      def stale_request_reason(checkpoint, request)
        RequestStaleness.new(self).reason(checkpoint, request)
      end

      def update_state(
        update,
        thread:,
        checkpoint_id: nil,
        execution_id: SecureRandom.uuid
      )
        StateOperations.new(self).update(
          update,
          thread:,
          checkpoint_id:,
          execution_id:
        )
      end

      def append_checkpoint(writer:, **attributes)
        StateOperations.new(self).append_checkpoint(writer:, **attributes)
      end

      def snapshot(checkpoint)
        StateOperations.new(self).snapshot(checkpoint)
      end

      def state_manager = @state_manager
      def planner = @planner
      def route_planner = @route_planner

      def pool_for(concurrency) = @pools.fetch(concurrency.to_sym)

      private

      def resolve_checkpointer(value)
        return value unless value.respond_to?(:bind_graph)

        value.bind_graph(checkpoint_codec: @checkpoint_codec)
      end

      def build_pools(pools)
        return pools if pools

        {
          inline: Pool.for(:inline, max_tasks: limits.max_tasks_per_step),
          threads: Pool.for(:threads, max_tasks: limits.max_tasks_per_step)
        }.freeze
      end

      def resume_answers = @resume_answers
      def invoke_at(...) = RunCoordinator.new(self).invoke(...)
      def resume_at(...) = RunCoordinator.new(self).resume(...)
      def retry_failed_at(...) = RunCoordinator.new(self).retry_failed(...)
      def continue_at(...) = RunCoordinator.new(self).continue(...)
      def invoke_with_writer(...) = WriterRunExecutor.new(self).invoke(...)
      def resume_with_writer(...) = WriterRunExecutor.new(self).resume(...)
      def retry_failed_with_writer(...) = WriterRunExecutor.new(self).retry_failed(...)
      def continue_with_writer(...) = WriterRunExecutor.new(self).continue(...)

      def execute_durable_request(request, writer:, concurrency:, context: nil)
        DurableRequestExecutor.new(self).execute(
          DurableRequestExecution.new(request, writer, concurrency, context)
        )
      end

      def latest_status(request, writer:)
        compatible_latest!(request.thread_id, namespace: request.namespace, writer:).status
      end

      def fork_with_writer(request, writer:, concurrency:, context:)
        execution = DurableRequestExecution.new(request, writer, concurrency, context)
        ForkExecutor.new(self).execute(execution)
      end

      def with_checkpointer(value)
        return self if value.equal?(checkpointer)

        self.class.new(
          definition:,
          definition_digest:,
          codec:,
          checkpointer: value,
          limits:,
          pools: @pools
        )
      end

      def compatible_latest!(...) = ExecutionSupport.new(self).compatible_latest!(...)
      def compatible!(...) = ExecutionSupport.new(self).compatible!(...)
      def stale_status_reason(...) = ExecutionSupport.new(self).stale_status_reason(...)
      def stale_resume_reason(...) = ExecutionSupport.new(self).stale_resume_reason(...)
      def merge_resume_values(...) = ExecutionSupport.new(self).merge_resume_values(...)
      def build_context(...) = ExecutionSupport.new(self).build_context(...)
      def bind_writer_context(...) = ExecutionSupport.new(self).bind_writer_context(...)
      def open_writer(...) = ExecutionSupport.new(self).open_writer(...)
      def ensure_ephemeral_public!(...) = ExecutionSupport.new(self).ensure_ephemeral_public!(...)
      def stream_error_data(...) = ExecutionSupport.new(self).stream_error_data(...)
      def validate_concurrency!(...) = ExecutionSupport.new(self).validate_concurrency!(...)
    end
  end
end
