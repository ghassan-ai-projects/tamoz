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
        ensure_ephemeral_public!
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
        ensure_ephemeral_public!
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
        ensure_ephemeral_public!
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
        ensure_ephemeral_public!
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
        ensure_ephemeral_public!
        open_writer(thread, []) do |writer|
          latest = compatible_latest!(thread, writer:)
          source = checkpoint_id ? writer.find(checkpoint_id:) : latest
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
            writer:,
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

      def append_checkpoint(writer:, **attributes)
        state = attributes.fetch(:state)
        attributes[:execution_id] = SafeText.normalize(
          attributes.fetch(:execution_id),
          name: "execution id",
          max_bytes: 256,
          error_class: ConfigurationError
        )
        attributes.delete(:thread)
        attributes.delete(:namespace)
        consumed_task_ids = attributes.delete(:consumed_task_ids) || []
        request_transition = attributes.delete(:request_transition)
        writer.append_checkpoint(
          expected_base_id: attributes.delete(:expected_base_id),
          mode: attributes.delete(:mode),
          attributes: {
            graph_name: name,
            graph_version: version,
            definition_digest:,
            state_bytes: @state_manager.state_bytes(state),
            **attributes
          },
          consumed_task_ids:,
          request_transition:
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
        open_writer(thread, namespace) do |writer|
          invoke_with_writer(
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

      def resume_at(answers, thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          resume_with_writer(
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

      def retry_failed_at(thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          retry_failed_with_writer(
            thread:,
            namespace:,
            request_id:,
            concurrency:,
            context:,
            writer:
          )
        end
      end

      def continue_at(thread:, namespace:, request_id:, concurrency:, context:)
        open_writer(thread, namespace) do |writer|
          continue_with_writer(
            thread:,
            namespace:,
            request_id:,
            concurrency:,
            context:,
            writer:
          )
        end
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
        latest = writer.latest
        if latest && !new_execution
          raise StaleRequestError,
                "thread already exists; use resume, retry_failed, or new_execution: true"
        end
        mode = latest ? :turn : :start
        state = prepared_state ||
                @state_manager.initial(input || {}, remaining_steps: limits.max_steps)
        frontier = prepared_frontier || @route_planner.initial_frontier
        request_transition = if durable_request_id
                               writer.request_transition(
                                 request_id: durable_request_id,
                                 execution_id:,
                                 action: :running,
                                 graph_status: :running
                               )
                             end
        checkpoint = append_checkpoint(
          writer:,
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
          total_tasks: 0,
          request_transition:
        )
        run_context = bind_writer_context(run_context, writer)
        Executor.new(self).run(
          checkpoint,
          writer:,
          context: run_context,
          concurrency:,
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
        checkpoint = compatible_latest!(thread, namespace:, writer:)
        unless checkpoint.status == :paused
          raise StaleRequestError, "latest checkpoint is not paused"
        end
        resume_values = begin
          merge_resume_values(checkpoint, answers)
        rescue InvalidUpdateError => error
          # DR-4 critic hardening: in the DURABLE claim→execute window the
          # checkpoint can change between claim and merge (lease expiry + an
          # owner-B write), so an answer/index mismatch here is a STALE request —
          # the same class the claim-time validator catches. Surface it as
          # StaleRequestError so the runner's backstop terminal-fails it, never
          # an escaping InvalidUpdateError (the D-6 signature). The EPHEMERAL
          # path (durable_request_id nil) keeps InvalidUpdateError for direct
          # caller bugs (pinned by graph_interrupt_test).
          raise StaleRequestError, error.message if durable_request_id

          raise
        end
        if durable_request_id && mark_request_running
          writer.mark_request_running(
            request_id: durable_request_id,
            execution_id: checkpoint.execution_id
          )
        end
        run_context = build_context(
          context,
          thread:,
          request_id:,
          execution_id: checkpoint.execution_id,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        run_context = bind_writer_context(run_context, writer)
        Executor.new(self).run(
          checkpoint,
          writer:,
          context: run_context,
          concurrency:,
          resume_values:,
          durable_request_id:
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
        checkpoint = compatible_latest!(thread, namespace:, writer:)
        unless checkpoint.status == :failed
          raise StaleRequestError, "latest checkpoint is not failed"
        end
        if durable_request_id && mark_request_running
          writer.mark_request_running(
            request_id: durable_request_id,
            execution_id: checkpoint.execution_id
          )
        end
        run_context = build_context(
          context,
          thread:,
          request_id:,
          execution_id: checkpoint.execution_id,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        run_context = bind_writer_context(run_context, writer)
        Executor.new(self).run(
          checkpoint,
          writer:,
          context: run_context,
          concurrency:,
          durable_request_id:
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
        checkpoint = compatible_latest!(thread, namespace:, writer:)
        unless checkpoint.status == :running
          raise StaleRequestError, "latest checkpoint has no runnable frontier"
        end
        if durable_request_id && mark_request_running
          writer.mark_request_running(
            request_id: durable_request_id,
            execution_id: checkpoint.execution_id
          )
        end
        run_context = build_context(
          context,
          thread:,
          request_id:,
          execution_id: checkpoint.execution_id,
          cancellation: context&.cancellation || CancellationToken.new,
          emitter: context&.emitter || Emitter::Null::INSTANCE
        )
        run_context = bind_writer_context(run_context, writer)
        Executor.new(self).run(
          checkpoint,
          writer:,
          context: run_context,
          concurrency:,
          durable_request_id:
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
        checkpoint = if writer
                       writer.latest
                     else
                       checkpointer.latest(thread_id: thread, namespace:)
                     end
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

      def stale_status_reason(checkpoint, required, reason)
        checkpoint&.status == required ? nil : reason
      end

      # Refactored from `merge_resume_values`' task/call-index matching plus the
      # pre-merge duplicate check (DR-4 C3): (a) status paused, (b) answers' indices
      # match the current interrupts, (c) no answer index already merged into
      # `resume_values`. Returns a typed reason string or nil.
      def stale_resume_reason(checkpoint, request)
        @resume_answers.stale_reason(checkpoint, request)
      end

      def merge_resume_values(checkpoint, answers)
        @resume_answers.merge(checkpoint, answers)
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

      def bind_writer_context(context, writer)
        return context unless writer.respond_to?(:effects)
        if context.effects &&
           (!writer.respond_to?(:accepts_effects?) ||
            !writer.accepts_effects?(context.effects))
          raise ConfigurationError,
                "durable execution rejects an unbound effect journal"
        end

        if context.store &&
           (!writer.respond_to?(:accepts_store?) ||
            !writer.accepts_store?(context.store))
          raise ConfigurationError,
                "durable execution rejects an unbound Store"
        end

        context.with(effects: writer.effects, store: writer.store)
      end

      def open_writer(thread, namespace, owner_id: SecureRandom.uuid, ttl: nil, &block)
        actual_ttl = ttl ||
                     if checkpointer.respond_to?(:writer_ttl)
                       checkpointer.writer_ttl
                     else
                       DEFAULT_WRITER_TTL
                     end
        checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: actual_ttl,
          &block
        )
      end

      def ensure_ephemeral_public!
        return unless checkpointer.durable?

        raise ConfigurationError,
              "durable graph mutations require Tamoz::Graph::DurableRunner"
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

      private_constant :DEFAULT_WRITER_TTL
    end
  end
end
