# frozen_string_literal: true

require "securerandom"

module Tamoz
  module Graph
    class Compiled
      attr_reader :definition, :definition_digest, :codec, :checkpointer, :limits

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
        @checkpointer = checkpointer
        @limits = limits
        @state_manager = StateManager.new(channels: definition.channels, codec:)
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
        unless new_execution == true || new_execution == false
          raise ConfigurationError, "new_execution must be true or false"
        end
        validate_concurrency!(concurrency)
        run_context = build_context(
          context,
          thread:,
          request_id:,
          execution_id:,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        state = @state_manager.initial(input || {}, remaining_steps: limits.max_steps)
        frontier = @route_planner.initial_frontier

        invoke_at(
          input,
          thread:,
          namespace: [],
          request_id:,
          execution_id:,
          concurrency:,
          new_execution:,
          context: run_context,
          prepared_state: state,
          prepared_frontier: frontier
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
        StreamEmitter.validate_mode!(mode)
        sink = nil
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

        EventStream.new(sink:, join_grace:) do
          emitter.emit(
            :run_start,
            stream_context.namespace,
            {"graph" => name, "execution_id" => execution_id},
            run_id:
          )
          result = invoke(
            input,
            thread:,
            request_id:,
            execution_id:,
            concurrency:,
            new_execution:,
            context: stream_context
          )
          emitter.emit(
            :run_end,
            stream_context.namespace,
            {"graph" => name, "status" => result.status.to_s},
            run_id:
          )
          result
        rescue StandardError => error
          emitter.emit(
            :error,
            stream_context.namespace,
            stream_error_data(error),
            run_id:
          )
          raise
        end
      rescue StandardError
        sink&.finish
        raise
      end

      def resume(
        answers,
        thread:,
        request_id:,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        resume_at(
          answers,
          thread:,
          namespace: [],
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
        retry_failed_at(
          thread:,
          namespace: [],
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
        continue_at(
          thread:,
          namespace: [],
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
        checkpoint = if checkpoint_id
                       checkpointer.find(
                         thread_id: thread,
                         namespace:,
                         checkpoint_id:
                       )
                     else
                       checkpointer.latest(thread_id: thread, namespace:)
                     end
        raise CheckpointConflictError, "checkpoint not found" unless checkpoint

        compatible!(checkpoint)
        snapshot(checkpoint)
      end

      def history(thread:, namespace: [], limit: limits.history_limit)
        unless limit.is_a?(Integer) && limit.positive?
          raise ConfigurationError, "history limit must be a positive integer"
        end
        if limit > limits.history_limit
          raise StateLimitError, "history limit exceeds #{limits.history_limit}"
        end

        checkpointer.history(thread_id: thread, namespace:, limit:).map do |checkpoint|
          compatible!(checkpoint)
          snapshot(checkpoint)
        end.freeze
      end

      def update_state(
        update,
        thread:,
        checkpoint_id: nil,
        execution_id: SecureRandom.uuid
      )
        checkpointer.synchronize(thread_id: thread, namespace: []) do
          latest = compatible_latest!(thread)
          source = checkpoint_id ? checkpointer.find(
            thread_id: thread,
            checkpoint_id:,
            namespace: []
          ) : latest
          raise CheckpointConflictError, "checkpoint not found" unless source

          compatible!(source)
          normalized = @state_manager.normalize_update(update)
          manual = Outcome.new(
            task_id: "manual.update",
            attempt_id: "manual.attempt",
            base_checkpoint_id: source.id,
            node: definition.nodes.keys.first,
            path: %w[manual update],
            update: normalized,
            goto: nil
          )
          remaining = [limits.max_steps - source.logical_step, 0].max
          candidate = @state_manager.apply_outcomes(
            source.state,
            [manual],
            remaining_steps: remaining
          )
          historical = source.id != latest.id
          frontier = source.frontier.map do |entry|
            historical ? entry.with(activation_checkpoint_id: nil) : entry
          end.freeze
          checkpoint = append_checkpoint(
            thread:,
            namespace: [],
            expected_base_id: source.id,
            mode: historical ? :fork : :advance,
            execution_id: historical ? execution_id : source.execution_id,
            state: candidate,
            status: frontier.empty? ? :completed : :running,
            logical_step: source.logical_step,
            frontier:,
            pending: {},
            interrupts: [],
            resume_values: {},
            attempts: historical ? {} : source.attempts,
            failure: nil,
            total_tasks: historical ? 0 : source.total_tasks
          )
          snapshot(checkpoint)
        end
      end

      def append_checkpoint(**attributes)
        state = attributes.fetch(:state)
        attributes[:execution_id] = SafeText.normalize(
          attributes.fetch(:execution_id),
          name: "execution id",
          max_bytes: 256,
          error_class: ConfigurationError
        )
        checkpointer.append(
          thread_id: attributes.delete(:thread),
          namespace: attributes.delete(:namespace),
          expected_base_id: attributes.delete(:expected_base_id),
          mode: attributes.delete(:mode),
          attributes: {
            graph_name: name,
            graph_version: version,
            definition_digest:,
            state_bytes: @state_manager.state_bytes(state),
            **attributes
          }
        )
      end

      def snapshot(checkpoint)
        Snapshot.new(
          checkpoint_id: checkpoint.id,
          parent_checkpoint_id: checkpoint.parent_id,
          sequence: checkpoint.sequence,
          thread_id: checkpoint.thread_id,
          namespace: checkpoint.namespace,
          execution_id: checkpoint.execution_id,
          status: checkpoint.status,
          logical_step: checkpoint.logical_step,
          state: checkpoint.state,
          next: checkpoint.frontier.map(&:node).uniq.freeze,
          pending_task_ids: checkpoint.pending.keys.sort.freeze,
          interrupts: checkpoint.interrupts,
          failure: checkpoint.failure,
          definition_digest: checkpoint.definition_digest
        )
      end

      def state_manager = @state_manager
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
        unless new_execution == true || new_execution == false
          raise ConfigurationError, "new_execution must be true or false"
        end
        validate_concurrency!(concurrency)
        run_context = build_context(
          context,
          thread:,
          request_id:,
          execution_id:,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        checkpointer.synchronize(thread_id: thread, namespace:) do
          latest = checkpointer.latest(thread_id: thread, namespace:)
          if latest && !new_execution
            raise CheckpointConflictError,
                  "thread already exists; use resume, retry_failed, or new_execution: true"
          end
          mode = latest ? :turn : :start
          state = prepared_state ||
                  @state_manager.initial(input || {}, remaining_steps: limits.max_steps)
          frontier = prepared_frontier || @route_planner.initial_frontier
          checkpoint = append_checkpoint(
            thread:,
            namespace:,
            expected_base_id: latest&.id,
            mode:,
            execution_id:,
            state:,
            status: :running,
            logical_step: 0,
            frontier:,
            pending: {},
            interrupts: [],
            resume_values: {},
            attempts: {},
            failure: nil,
            total_tasks: 0
          )
          Executor.new(self).run(checkpoint, context: run_context, concurrency:)
        end
      end

      def resume_at(answers, thread:, namespace:, request_id:, concurrency:, context:)
        checkpointer.synchronize(thread_id: thread, namespace:) do
          checkpoint = compatible_latest!(thread, namespace:)
          unless checkpoint.status == :paused
            raise CheckpointConflictError, "latest checkpoint is not paused"
          end
          resume_values = merge_resume_values(checkpoint, answers)
          run_context = build_context(
            context,
            thread:,
            request_id:,
            execution_id: checkpoint.execution_id,
            cancellation: context&.cancellation || CancellationToken.new,
            emitter: context&.emitter || Emitter::Null::INSTANCE
          )
          Executor.new(self).run(
            checkpoint,
            context: run_context,
            concurrency:,
            resume_values:
          )
        end
      end

      def retry_failed_at(thread:, namespace:, request_id:, concurrency:, context:)
        checkpointer.synchronize(thread_id: thread, namespace:) do
          checkpoint = compatible_latest!(thread, namespace:)
          unless checkpoint.status == :failed
            raise CheckpointConflictError, "latest checkpoint is not failed"
          end
          run_context = build_context(
            context,
            thread:,
            request_id:,
            execution_id: checkpoint.execution_id,
            cancellation: context&.cancellation || CancellationToken.new,
            emitter: context&.emitter || Emitter::Null::INSTANCE
          )
          Executor.new(self).run(checkpoint, context: run_context, concurrency:)
        end
      end

      def continue_at(thread:, namespace:, request_id:, concurrency:, context:)
        checkpointer.synchronize(thread_id: thread, namespace:) do
          checkpoint = compatible_latest!(thread, namespace:)
          unless checkpoint.status == :running
            raise CheckpointConflictError, "latest checkpoint has no runnable frontier"
          end
          run_context = build_context(
            context,
            thread:,
            request_id:,
            execution_id: checkpoint.execution_id,
            cancellation: context&.cancellation || CancellationToken.new,
            emitter: context&.emitter || Emitter::Null::INSTANCE
          )
          Executor.new(self).run(checkpoint, context: run_context, concurrency:)
        end
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

      def compatible_latest!(thread, namespace: [])
        checkpoint = checkpointer.latest(thread_id: thread, namespace:)
        raise CheckpointConflictError, "thread does not exist" unless checkpoint

        compatible!(checkpoint)
        checkpoint
      end

      def compatible!(checkpoint)
        return checkpoint if checkpoint.graph_name == name &&
                             checkpoint.graph_version == version &&
                             checkpoint.definition_digest == definition_digest

        raise CheckpointVersionError, "checkpoint graph identity is incompatible"
      end

      def merge_resume_values(checkpoint, answers)
        raise InvalidUpdateError, "resume answers must be a Hash" unless answers.is_a?(Hash)

        expected = checkpoint.interrupts.to_h do |interrupt|
          [[interrupt.task_id, interrupt.call_index], true]
        end
        additions = {}
        answers.each do |raw_task_id, raw_indices|
          task_id = String(raw_task_id)
          raise InvalidUpdateError, "resume task answers must be a Hash" unless raw_indices.is_a?(Hash)

          raw_indices.each do |raw_index, value|
            index = Integer(raw_index, exception: false)
            unless index && index >= 0 && expected.key?([task_id, index])
              raise InvalidUpdateError,
                    "resume answer does not match an outstanding task/call index"
            end
            additions[task_id] ||= {}
            additions[task_id][index] = codec.normalize(value)
          end
        end
        raise InvalidUpdateError, "resume answers cannot be empty" if additions.empty?

        merged = checkpoint.resume_values.to_h do |task_id, values|
          [task_id, values.dup]
        end
        additions.each do |task_id, values|
          merged[task_id] ||= {}
          values.each do |index, value|
            if merged.fetch(task_id).key?(index)
              raise InvalidUpdateError, "resume answer already exists for #{task_id}/#{index}"
            end
            merged.fetch(task_id)[index] = value
          end
        end
        merged.transform_values { |values| values.freeze }.freeze
      end

      def build_context(base, thread:, request_id:, execution_id:, cancellation:, emitter:)
        if base
          return base.with(
            execution_id:,
            request_id:,
            thread_id: thread,
            cancellation:,
            emitter:
          )
        end

        Context.new(
          run_id: SecureRandom.uuid,
          execution_id:,
          request_id:,
          thread_id: thread,
          cancellation:,
          emitter:
        )
      end

      def stream_error_data(error)
        {
          "graph" => name,
          "error_class" => error.class.name.to_s,
          "category" => error.respond_to?(:category) ? error.category : "internal",
          "safe_message" => if error.respond_to?(:safe_message)
                              error.safe_message
                            else
                              "The graph stream failed."
                            end
        }.freeze
      end

      def validate_concurrency!(value)
        return if %i[inline threads].include?(value)
        return if %w[inline threads].include?(value)

        raise ConfigurationError, "concurrency must be inline or threads"
      end
    end
  end
end
