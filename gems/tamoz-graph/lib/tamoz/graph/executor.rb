# frozen_string_literal: true

module Tamoz
  module Graph
    class Executor
      attr_reader :compiled, :limits

      def initialize(compiled)
        @compiled = compiled
        @limits = compiled.limits
      end

      def run(
        checkpoint,
        writer:,
        context:,
        concurrency:,
        resume_values: checkpoint.resume_values,
        durable_request_id: nil
      )
        current = checkpoint
        loop do
          context.check!
          writer.check!
          return completed(current) if current.frontier.empty?

          logical_step = current.frontier.map(&:logical_step).max
          if logical_step > limits.max_steps
            raise RecursionLimitError,
                  "graph #{compiled.name} exceeds #{limits.max_steps} super-steps"
          end

          tasks = compiled.planner.tasks(current)
          scheduled_by_id = tasks.to_h { |task| [task.id, task] }
          pending = current.pending.select { |task_id, _outcome| scheduled_by_id.key?(task_id) }
          to_execute = tasks.reject { |task| pending.key?(task.id) }
          enforce_task_limits!(current, tasks, to_execute)
          results = execute_tasks(
            to_execute,
            current,
            writer:,
            context:,
            concurrency:,
            resume_values:
          )
          attempts = current.attempts.merge(
            to_execute.to_h { |task| [task.id, task.attempt] }
          ).freeze
          successes, interruptions, errors, pool_cancelled = classify_pool_results(
            to_execute,
            results,
            current
          )
          return cancelled(current) if pool_cancelled || context.cancelled?

          all_successes = pending.merge(successes).freeze
          enforce_pending_limit!(all_successes)
          total_tasks = current.total_tasks + to_execute.length

          unless errors.empty?
            failed = append_failed_checkpoint(
              current,
              writer:,
              context:,
              pending: all_successes,
              interrupts: interruptions,
              attempts:,
              resume_values:,
              total_tasks:,
              errors:,
              request_id: durable_request_id
            )
            return RunResult.new(
              status: :failed,
              snapshot: compiled.snapshot(failed),
              interrupts: failed.interrupts,
              errors: errors.freeze
            )
          end

          unless interruptions.empty?
            if context.interrupt_mode == :non_interactive
              return non_interactive_interrupt(
                current,
                interruptions,
                tasks:,
                pending: all_successes,
                writer:,
                context:,
                attempts:,
                resume_values:,
                total_tasks:,
                durable_request_id:
              )
            end

            paused = append_paused_checkpoint(
              current,
              writer:,
              context:,
              pending: all_successes,
              interrupts: interruptions,
              attempts:,
              resume_values:,
              total_tasks:,
              request_id: durable_request_id
            )
            return RunResult.new(
              status: :paused,
              snapshot: compiled.snapshot(paused),
              interrupts: interruptions,
              errors: [].freeze
            )
          end

          ordered = tasks.sort_by(&:path).map do |task|
            outcome = all_successes.fetch(task.id)
            validate_outcome!(task, outcome, current, pending: pending.key?(task.id))
            outcome
          end
          remaining = [limits.max_steps - logical_step, 0].max
          candidate = compiled.state_manager.apply_outcomes(
            current.state,
            ordered,
            remaining_steps: remaining
          )
          frontier = compiled.route_planner.next_frontier(
            ordered,
            candidate,
            logical_step: logical_step + 1
          )
          context.check!
          writer.check!
          completion_transition = if frontier.empty?
                                    terminal_request_transition(
                                      writer,
                                      request_id: durable_request_id,
                                      execution_id: current.execution_id,
                                      action: :completed,
                                      graph_status: :completed
                                    )
                                  end
          current = compiled.append_checkpoint(
            writer:,
            thread: current.thread_id,
            namespace: current.namespace,
            expected_base_id: current.id,
            mode: :advance,
            execution_id: current.execution_id,
            state: candidate,
            status: frontier.empty? ? :completed : :running,
            logical_step:,
            frontier:,
            pending: {}.freeze,
            interrupts: [].freeze,
            resume_values:,
            attempts:,
            failure: nil,
            total_tasks:,
            consumed_task_ids: tasks.map(&:id),
            request_transition: completion_transition
          )
          ordered.each { |outcome| emit_update(context, outcome) }
          emit_checkpoint(context, current)
        end
      rescue CancelledError, TimeoutError
        cancelled(current)
      end

      private

      def execute_tasks(
        tasks,
        checkpoint,
        writer:,
        context:,
        concurrency:,
        resume_values:
      )
        return [] if tasks.empty?

        pool = compiled.pool_for(concurrency)
        pool.map(tasks, cancellation: context.cancellation) do |task|
          execute_task(
            task,
            checkpoint,
            writer:,
            context:,
            concurrency:,
            resume_values: resume_values.fetch(task.id, {}.freeze)
          )
        end
      end

      def execute_task(
        task,
        checkpoint,
        writer:,
        context:,
        concurrency:,
        resume_values:
      )
        cursor = InterruptCursor.new(task_id: task.id, resume_values:)
        task_context = context.with(
          run_id: task.id,
          parent_run_id: context.run_id,
          namespace: [*context.namespace, *task.path],
          task_id: task.id,
          interrupts: cursor,
          graph_runtime: SubgraphRuntime.new(
            parent: compiled,
            checkpoint:,
            task:,
            concurrency:
          )
        )
        task_context.emit(
          :task_start,
          {
            "graph" => compiled.name,
            "node" => task.node.to_s,
            "attempt" => task.attempt
          }
        )
        outcome = invoke_node(task, checkpoint, task_context)
        task_context.emit(
          :task_end,
          {
            "graph" => compiled.name,
            "node" => task.node.to_s,
            "status" => "succeeded"
          }
        )
        writer.append_writes(task:, outcome:)
        outcome
      end

      def invoke_node(task, checkpoint, task_context)
        input = task.input ? compiled.state_manager.task_input(task.input) : checkpoint.state
        returned = compiled.nodes.fetch(task.node).call(input, task_context)
        update, routes = normalize_return(returned)
        Outcome.new(
          task_id: task.id,
          attempt_id: task.attempt_id,
          base_checkpoint_id: task.base_checkpoint_id,
          node: task.node,
          path: task.path,
          update:,
          goto: routes
        )
      end

      def normalize_return(value)
        case value
        when nil
          [{}.freeze, nil]
        when Hash
          [compiled.state_manager.normalize_update(value), nil]
        when Command
          if value.resume || value.graph
            raise InvalidUpdateError,
                  "node Command may contain only update and goto in M2"
          end
          [compiled.state_manager.normalize_update(value.update), value.goto]
        else
          raise InvalidUpdateError,
                "node must return nil, Hash, or Tamoz::Command; got #{value.class}"
        end
      end

      def classify_pool_results(tasks, results, checkpoint)
        successes = {}
        interruptions = []
        errors = []
        pool_cancelled = false
        results.each_with_index do |result, index|
          task = tasks.fetch(index)
          case result
          when TaskResult::Succeeded
            successes[task.id] = result.value
          when TaskResult::Fatal
            raise result.error
          when TaskResult::Interrupted
            descriptor = result.descriptor
            unless descriptor.fetch("task_id") == task.id
              raise CheckpointConflictError, "interrupt task identity is stale or mismatched"
            end
            interruptions << Interrupt.new(
              task_id: descriptor.fetch("task_id"),
              call_index: descriptor.fetch("call_index"),
              descriptor: descriptor.fetch("descriptor")
            )
          when TaskResult::Failed
            errors << node_error(task, result.error)
          when TaskResult::Cancelled, TaskResult::Stuck
            pool_cancelled = true
          else
            raise PoolWorkerError, "unknown pool result #{result.class}"
          end
        end
        [successes.freeze, interruptions.sort_by(&:key).freeze, errors.freeze, pool_cancelled]
      end

      def node_error(task, original)
        NodeError.new(
          "graph #{compiled.name} node #{task.node} failed with #{original.class}",
          graph_name: compiled.name,
          node: task.node,
          task_id: task.id,
          attempt_id: task.attempt_id,
          original:
        )
      end

      def validate_outcome!(task, outcome, checkpoint, pending:)
        return if pending && outcome.task_id == task.id
        return if !pending &&
                  outcome.task_id == task.id &&
                  outcome.attempt_id == task.attempt_id &&
                  outcome.base_checkpoint_id == checkpoint.id

        raise CheckpointConflictError,
              "stale or mismatched result for logical task #{task.id}"
      end

      def append_noncommitting(
        checkpoint,
        writer:,
        status:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        failure:,
        request_transition:
      )
        compiled.append_checkpoint(
          writer:,
          thread: checkpoint.thread_id,
          namespace: checkpoint.namespace,
          expected_base_id: checkpoint.id,
          mode: :advance,
          execution_id: checkpoint.execution_id,
          state: checkpoint.state,
          status:,
          logical_step: checkpoint.logical_step,
          frontier: checkpoint.frontier,
          pending:,
          interrupts:,
          resume_values:,
          attempts:,
          failure:,
          total_tasks:,
          request_transition:
        )
      end

      def terminal_request_transition(
        writer,
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        return nil unless request_id
        unless writer.respond_to?(:request_transition)
          raise ConfigurationError,
                "durable request execution requires a request-capable writer"
        end

        writer.request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status:,
          retryable:
        )
      end

      def append_failed_checkpoint(
        checkpoint,
        writer:,
        context:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        errors:,
        request_id:
      )
        failed = append_noncommitting(
          checkpoint,
          writer:,
          status: :failed,
          pending:,
          interrupts:,
          attempts:,
          resume_values:,
          total_tasks:,
          failure: failure_descriptors(errors),
          request_transition: terminal_request_transition(
            writer,
            request_id:,
            execution_id: checkpoint.execution_id,
            action: :failed,
            graph_status: :failed,
            retryable: false
          )
        )
        emit_errors(context, errors)
        emit_checkpoint(context, failed)
        failed
      end

      def append_paused_checkpoint(
        checkpoint,
        writer:,
        context:,
        pending:,
        interrupts:,
        attempts:,
        resume_values:,
        total_tasks:,
        request_id:
      )
        paused = append_noncommitting(
          checkpoint,
          writer:,
          status: :paused,
          pending:,
          interrupts:,
          attempts:,
          resume_values:,
          total_tasks:,
          failure: nil,
          request_transition: terminal_request_transition(
            writer,
            request_id:,
            execution_id: checkpoint.execution_id,
            action: :completed,
            graph_status: :paused
          )
        )
        emit_interrupts(context, interrupts)
        emit_checkpoint(context, paused)
        paused
      end

      def enforce_task_limits!(checkpoint, tasks, to_execute)
        if tasks.length > limits.max_tasks_per_step
          raise RecursionLimitError,
                "graph step has #{tasks.length} tasks; limit is #{limits.max_tasks_per_step}"
        end
        if checkpoint.total_tasks + to_execute.length > limits.max_total_tasks
          raise RecursionLimitError,
                "graph scheduled tasks exceed #{limits.max_total_tasks}"
        end
      end

      def enforce_pending_limit!(pending)
        bytes = Canonical.json(
          pending.keys.sort.map { |task_id| pending.fetch(task_id).descriptor }
        ).bytesize
        return if bytes <= limits.max_pending_bytes

        raise StateLimitError,
              "pending outcomes use #{bytes} bytes; limit is #{limits.max_pending_bytes}"
      end

      def failure_descriptors(errors)
        errors.map do |error|
          {
            "graph" => error.graph_name,
            "node" => error.node,
            "task_id" => error.task_id,
            "attempt_id" => error.attempt_id,
            "error_class" => stable_error_class(error.original),
            "safe_message" => error.safe_message
          }.freeze
        end.freeze
      end

      # T0.4: in a non-interactive episode an interrupt is a typed terminal
      # failure — the graph fails fast with a durable failed checkpoint and
      # never waits for a resume value that cannot arrive (no wall-clock
      # budget consumed waiting).
      def non_interactive_interrupt(
        current,
        interruptions,
        tasks:,
        pending:,
        writer:,
        context:,
        attempts:,
        resume_values:,
        total_tasks:,
        durable_request_id:
      )
        first = interruptions.first
        interrupted_task = tasks.find { |task| task.id == first.task_id }
        node = interrupted_task ? interrupted_task.node : first.task_id
        error = InterruptInNonInteractiveEpisodeError.new(
          "graph #{compiled.name} node interrupted in non-interactive episode",
          task_id: first.task_id,
          descriptor: first.descriptor
        )
        node_failure = NodeError.new(
          error.message,
          graph_name: compiled.name,
          node:,
          task_id: first.task_id,
          attempt_id: nil,
          original: error
        )
        failed = append_failed_checkpoint(
          current,
          writer:,
          context:,
          pending:,
          interrupts: interruptions,
          attempts:,
          resume_values:,
          total_tasks:,
          errors: [node_failure],
          request_id: durable_request_id
        )
        RunResult.new(
          status: :failed,
          snapshot: compiled.snapshot(failed),
          interrupts: interruptions,
          errors: [node_failure].freeze
        )
      end

      def completed(checkpoint)
        RunResult.new(
          status: :completed,
          snapshot: compiled.snapshot(checkpoint),
          interrupts: [].freeze,
          errors: [].freeze
        )
      end

      def cancelled(checkpoint)
        RunResult.new(
          status: :cancelled,
          snapshot: compiled.snapshot(checkpoint),
          interrupts: checkpoint.interrupts,
          errors: [].freeze
        )
      end

      def emit_update(context, outcome)
        context.emit(
          :node_update,
          {
            "graph" => compiled.name,
            "node" => outcome.node.to_s,
            "channels" => outcome.update.keys.map(&:to_s).sort
          }
        )
      end

      def emit_interrupts(context, interrupts)
        interrupts.each do |interrupt|
          context.emit(
            :interrupt,
            {
              "graph" => compiled.name,
              "task_id" => interrupt.task_id,
              "call_index" => interrupt.call_index
            }
          )
        end
      end

      def emit_checkpoint(context, checkpoint)
        context.emit(
          :checkpoint,
          {
            "graph" => compiled.name,
            "checkpoint_id" => checkpoint.id,
            "sequence" => checkpoint.sequence,
            "status" => checkpoint.status.to_s
          }
        )
      end

      def emit_errors(context, errors)
        errors.each do |error|
          context.emit(
            :error,
            {
              "graph" => compiled.name,
              "node" => error.node,
              "task_id" => error.task_id,
              "error_class" => stable_error_class(error.original),
              "category" => error.category,
              "safe_message" => error.safe_message
            }
          )
        end
      end

      def stable_error_class(error)
        name = error.class.name.to_s
        name.empty? ? "AnonymousError" : name
      end
    end

    private_constant :Executor
  end
end
