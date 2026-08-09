# frozen_string_literal: true

module Tamoz
  module Graph
    # Creates a new checkpoint lineage from a durable fork request.
    # :reek:FeatureEnvy :reek:DuplicateMethodCall -- this collaborator is the
    # fork adapter; graph state, checkpoint, and execution contracts remain owned
    # by Compiled and are intentionally called through that narrow boundary.
    # :reek:ControlParameter :reek:LongParameterList :reek:RepeatedConditional
    # :reek:TooManyStatements :reek:UtilityFunction -- checkpoint construction
    # is one protocol operation; splitting its attributes into generic helpers
    # would obscure the durable fork contract.
    # :reek:MissingSafeMethod -- execute enforces a durable state transition and
    # has no meaningful non-raising twin.
    class ForkExecutor
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def execute(execution)
        return continue_after_claim(execution) if execution.request.status == :running

        source, update = fork_source_and_update(execution)
        state = fork_state(source, update)
        frontier = reset_frontier(source)
        terminal = frontier.empty?
        checkpoint = append_checkpoint(execution, source, state, frontier, terminal)
        return compiled.snapshot(checkpoint) if terminal

        run_checkpoint(execution, checkpoint)
      end

      private

      attr_reader :compiled

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

      def fork_source_and_update(execution)
        request = execution.request
        payload = request.payload
        raise InvalidUpdateError, 'fork payload must be a Hash' unless payload.is_a?(Hash)

        checkpoint_id = payload['checkpoint_id'] || payload[:checkpoint_id]
        update = if payload.key?('update')
                   payload['update']
                 elsif payload.key?(:update)
                   payload[:update]
                 else
                   {}
                 end
        source = checkpoint_id ? execution.writer.find(checkpoint_id:) : execution.writer.latest
        raise CheckpointConflictError, 'fork source checkpoint does not exist' unless source

        compiled.__send__(:compatible!, source)
        [source, update]
      end

      def fork_state(source, update)
        return source.state if update.empty?

        state_manager = compiled.state_manager
        state_manager.apply_outcomes(
          source.state,
          [fork_outcome(source, update, state_manager)],
          remaining_steps: [compiled.limits.max_steps - source.logical_step, 0].max
        )
      end

      def fork_outcome(source, update, state_manager)
        Outcome.new(
          task_id: 'fork.update',
          attempt_id: 'fork.attempt',
          base_checkpoint_id: source.id,
          node: compiled.definition.nodes.keys.first,
          path: %w[fork update],
          update: state_manager.normalize_update(update),
          goto: nil
        )
      end

      def reset_frontier(source)
        source.frontier.map { |entry| entry.with(activation_checkpoint_id: nil) }.freeze
      end

      def append_checkpoint(execution, source, state, frontier, terminal)
        status = terminal ? :completed : :running
        compiled.append_checkpoint(**checkpoint_attributes(
          execution,
          source,
          state,
          frontier,
          status
        ))
      end

      def request_transition(execution, status)
        request = execution.request
        execution.writer.request_transition(
          request_id: request.request_id,
          execution_id: request.execution_id,
          action: status,
          graph_status: status
        )
      end

      def checkpoint_attributes(execution, source, state, frontier, status)
        request = execution.request
        {
          writer: execution.writer,
          thread: request.thread_id,
          namespace: request.namespace,
          expected_base_id: source.id,
          mode: :fork,
          execution_id: request.execution_id,
          state:,
          status:,
          logical_step: source.logical_step,
          frontier:,
          pending: {},
          interrupts: [],
          resume_values: {},
          attempts: {},
          failure: nil,
          total_tasks: 0,
          request_transition: request_transition(execution, status)
        }
      end

      def run_checkpoint(execution, checkpoint)
        request = execution.request
        Executor.new(compiled).run(
          checkpoint,
          writer: execution.writer,
          context: execution_context(execution),
          concurrency: execution.concurrency,
          durable_request_id: request.request_id
        )
      end

      def execution_context(execution)
        request = execution.request
        context = compiled.__send__(
          :build_context,
          execution.context,
          thread: request.thread_id,
          request_id: request.request_id,
          execution_id: request.execution_id,
          cancellation: execution.context&.cancellation || CancellationToken.new,
          emitter: execution.context&.emitter || Emitter::Null::INSTANCE
        )
        compiled.__send__(:bind_writer_context, context, execution.writer)
      end
    end
  end
end
