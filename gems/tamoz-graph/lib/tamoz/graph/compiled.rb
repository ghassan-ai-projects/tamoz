# frozen_string_literal: true

require "securerandom"

module Tamoz
  module Graph
    class Compiled
      DEFAULT_WRITER_TTL = 30.0

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
        @checkpointer = if checkpointer.respond_to?(:bind_graph)
                          checkpointer.bind_graph(checkpoint_codec: @checkpoint_codec)
                        else
                          checkpointer
                        end
        @planner = Planner.new(definition_digest:)
        @route_planner = RoutePlanner.new(definition:)
        @pools = pools || {
          inline: Pool.for(:inline, max_tasks: limits.max_tasks_per_step),
          threads: Pool.for(:threads, max_tasks: limits.max_tasks_per_step)
        }.freeze
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
          raise ConfigurationError,
                "compiled graph invocation requires a parent graph task Context"
        end

        runtime.call(self, input, context)
      end

      def state(thread:, checkpoint_id: nil, namespace: [])
        StateOperations.new(self).state(thread:, checkpoint_id:, namespace:)
      end

      def history(thread:, namespace: [], limit: limits.history_limit)
        StateOperations.new(self).history(thread:, namespace:, limit:)
      end

      def durable_runner
        DurableRunner.new(self)
      end

      # Pure staleness predicate for a durable request against the thread's latest
      # checkpoint (DR-4). The graph owns this predicate; callers (the claim
      # transaction, the recover transaction, and the runner backstop) supply nothing.
      # Returns nil when the request is still applicable, or a bounded, typed reason
      # string when it can no longer run. `:redirect` is deliberately NOT validated —
      # its wait condition is legitimate and must retry, never terminal-fail.
      #
      # The reason strings are framework-authored and never interpolate untrusted
      # payload content (only bounded numeric indices), so they are safe to persist in
      # `terminal_error` (invariant 24).
      def stale_request_reason(checkpoint, request)
        case request.operation
        when :redirect
          nil
        when :resume
          # A resume already `running` after a barrier commit continues the
          # interrupted execution (invariant 52); only the full validation applies to
          # claim-time and recovered-but-unstarted requests.
          if request.status == :running && checkpoint&.status == :running
            nil
          else
            stale_resume_reason(checkpoint, request)
          end
        when :retry
          stale_status_reason(checkpoint, :failed, "latest checkpoint is not failed")
        when :continue
          stale_status_reason(
            checkpoint,
            :running,
            "latest checkpoint has no runnable frontier"
          )
        when :turn, :fork
          if request.status == :running
            stale_status_reason(
              checkpoint,
              :running,
              "latest checkpoint has no runnable frontier"
            )
          elsif checkpoint && !%i[completed failed].include?(checkpoint.status)
            "latest checkpoint is not terminal"
          end
        end
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
      def resume_answers = @resume_answers
      def planner = @planner
      def route_planner = @route_planner

      def pool_for(concurrency)
        @pools.fetch(concurrency.to_sym)
      end

      private

      def invoke_at(
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
        RunCoordinator.new(self).invoke(
          input,
          thread:,
          namespace:,
          request_id:,
          execution_id:,
          concurrency:,
          new_execution:,
          context:,
          prepared_state:,
          prepared_frontier:
        )
      end

      def resume_at(answers, thread:, namespace:, request_id:, concurrency:, context:)
        RunCoordinator.new(self).resume(
          answers,
          thread:,
          namespace:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def retry_failed_at(thread:, namespace:, request_id:, concurrency:, context:)
        RunCoordinator.new(self).retry_failed(
          thread:,
          namespace:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def continue_at(thread:, namespace:, request_id:, concurrency:, context:)
        RunCoordinator.new(self).continue(
          thread:,
          namespace:,
          request_id:,
          concurrency:,
          context:
        )
      end

      def invoke_with_writer(
        input,
        thread:,
        namespace:,
        request_id:,
        execution_id:,
        concurrency:,
        new_execution:,
        run_context:,
        writer:,
        prepared_state: nil,
        prepared_frontier: nil,
        durable_request_id: nil
      )
        WriterRunExecutor.new(self).invoke(
          input,
          thread:,
          namespace:,
          execution_id:,
          concurrency:,
          new_execution:,
          run_context:,
          writer:,
          prepared_state:,
          prepared_frontier:,
          durable_request_id:
        )
      end

      def resume_with_writer(
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
        WriterRunExecutor.new(self).resume(
          answers,
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

      def retry_failed_with_writer(
        thread:,
        namespace:,
        request_id:,
        concurrency:,
        context:,
        writer:,
        durable_request_id: nil,
        mark_request_running: true
      )
        WriterRunExecutor.new(self).retry_failed(
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

      def continue_with_writer(
        thread:,
        namespace:,
        request_id:,
        concurrency:,
        context:,
        writer:,
        durable_request_id: nil,
        mark_request_running: true
      )
        WriterRunExecutor.new(self).continue(
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

      def execute_durable_request(
        request,
        writer:,
        concurrency:,
        context: nil
      )
        DurableRequestExecutor.new(self).execute(
          DurableRequestExecution.new(request, writer, concurrency, context)
        )
      end

      def latest_status(request, writer:)
        compatible_latest!(
          request.thread_id,
          namespace: request.namespace,
          writer:
        ).status
      end

      def fork_with_writer(request, writer:, concurrency:, context:)
        ForkExecutor.new(self).execute(
          DurableRequestExecution.new(request, writer, concurrency, context)
        )
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

      def compatible_latest!(thread, namespace: [], writer: nil)
        ExecutionSupport.new(self).compatible_latest!(thread, namespace:, writer:)
      end

      def compatible!(checkpoint)
        ExecutionSupport.new(self).compatible!(checkpoint)
      end

      def stale_status_reason(checkpoint, required, reason)
        ExecutionSupport.new(self).stale_status_reason(checkpoint, required, reason)
      end

      # Refactored from `merge_resume_values`' task/call-index matching plus the
      # pre-merge duplicate check (DR-4 C3): (a) status paused, (b) answers' indices
      # match the current interrupts, (c) no answer index already merged into
      # `resume_values`. Returns a typed reason string or nil.
      def stale_resume_reason(checkpoint, request)
        ExecutionSupport.new(self).stale_resume_reason(checkpoint, request)
      end

      def merge_resume_values(checkpoint, answers)
        ExecutionSupport.new(self).merge_resume_values(checkpoint, answers)
      end

      def build_context(base, thread:, request_id:, execution_id:, cancellation:, emitter:)
        ExecutionSupport.new(self).build_context(
          base,
          thread:,
          request_id:,
          execution_id:,
          cancellation:,
          emitter:
        )
      end

      def bind_writer_context(context, writer)
        ExecutionSupport.new(self).bind_writer_context(context, writer)
      end

      def open_writer(thread, namespace, owner_id: SecureRandom.uuid, ttl: nil, &block)
        ExecutionSupport.new(self).open_writer(thread, namespace, owner_id:, ttl:, &block)
      end

      def ensure_ephemeral_public!
        ExecutionSupport.new(self).ensure_ephemeral_public!
      end

      def stream_error_data(error)
        ExecutionSupport.new(self).stream_error_data(error)
      end

      def validate_concurrency!(value)
        ExecutionSupport.new(self).validate_concurrency!(value)
      end

      private_constant :DEFAULT_WRITER_TTL
    end
  end
end
