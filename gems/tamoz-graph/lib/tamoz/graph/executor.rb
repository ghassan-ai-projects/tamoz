# frozen_string_literal: true

module Tamoz
  module Graph
    class Executor
      Execution = Data.define(:writer, :context, :concurrency, :resume_values, :request_id)
      Step = Data.define(:logical_step, :tasks, :pending, :successes, :interruptions, :errors,
                         :cancelled, :attempts, :total_tasks)

      attr_reader :compiled, :limits

      def initialize(compiled)
        @compiled = compiled
        @limits = compiled.limits
        @tasks = TaskExecution.new(compiled)
        @results = SuperstepResults.new(compiled)
        @events = ExecutionEvents.new(compiled)
        @checkpoints = ExecutionCheckpoints.new(compiled, @events)
      end

      def run(checkpoint, writer:, context:, concurrency:, resume_values: checkpoint.resume_values,
              durable_request_id: nil)
        current = checkpoint
        execution = Execution.new(writer:, context:, concurrency:, resume_values:, request_id: durable_request_id)
        loop do
          context.check!
          writer.check!
          return completed(current) if current.frontier.empty?

          step = execute_step(current, execution)
          return cancelled(current) if step.cancelled || context.cancelled?

          enforce_pending_limit!(step.successes)
          terminal = terminal_result(current, step, execution)
          return terminal if terminal

          ordered = ordered_outcomes(current, step)
          current = advance_checkpoint(current, step, ordered, execution)
          ordered.each { |outcome| @events.emit_update(context, outcome) }
          @events.emit_checkpoint(context, current)
        end
      rescue CancelledError, TimeoutError
        cancelled(current)
      end

      private

      def execute_step(current, execution)
        logical_step = current.frontier.map(&:logical_step).max
        enforce_step_limit!(logical_step)
        tasks = compiled.planner.tasks(current)
        scheduled_by_id = tasks.to_h { |task| [task.id, task] }
        pending = current.pending.select { |task_id, _outcome| scheduled_by_id.key?(task_id) }
        to_execute = tasks.reject { |task| pending.key?(task.id) }
        enforce_task_limits!(current, tasks, to_execute)
        results = @tasks.execute_tasks(
          to_execute, current, writer: execution.writer, context: execution.context,
                               concurrency: execution.concurrency, resume_values: execution.resume_values
        )
        attempts = current.attempts.merge(to_execute.to_h { |task| [task.id, task.attempt] }).freeze
        successes, interruptions, errors, pool_cancelled = @results.classify(to_execute, results)
        Step.new(logical_step:, tasks:, pending:, successes: pending.merge(successes).freeze,
                 interruptions:, errors:, cancelled: pool_cancelled, attempts:,
                 total_tasks: current.total_tasks + to_execute.length)
      end

      def enforce_step_limit!(logical_step)
        return if logical_step <= limits.max_steps

        raise RecursionLimitError, "graph #{compiled.name} exceeds #{limits.max_steps} super-steps"
      end

      def terminal_result(current, step, execution)
        return failed_result(current, step, execution) unless step.errors.empty?
        return if step.interruptions.empty?

        return non_interactive_result(current, step, execution) if execution.context.interrupt_mode == :non_interactive
        paused = @checkpoints.append_paused_checkpoint(current, **barrier_keywords(step, execution))
        RunResult.new(status: :paused, snapshot: compiled.snapshot(paused),
                      interrupts: step.interruptions, errors: [].freeze)
      end

      def failed_result(current, step, execution)
        failed = @checkpoints.append_failed_checkpoint(
          current, **barrier_keywords(step, execution), errors: step.errors
        )
        RunResult.new(status: :failed, snapshot: compiled.snapshot(failed),
                      interrupts: failed.interrupts, errors: step.errors.freeze)
      end

      def barrier_keywords(step, execution)
        { writer: execution.writer, context: execution.context, pending: step.successes,
          interrupts: step.interruptions, attempts: step.attempts, resume_values: execution.resume_values,
          total_tasks: step.total_tasks, request_id: execution.request_id }
      end

      def ordered_outcomes(current, step)
        step.tasks.sort_by(&:path).map do |task|
          outcome = step.successes.fetch(task.id)
          validate_outcome!(task, outcome, current, pending: step.pending.key?(task.id))
          outcome
        end
      end

      def advance_checkpoint(current, step, ordered, execution)
        remaining = [limits.max_steps - step.logical_step, 0].max
        candidate = compiled.state_manager.apply_outcomes(current.state, ordered, remaining_steps: remaining)
        frontier = compiled.route_planner.next_frontier(ordered, candidate, logical_step: step.logical_step + 1)
        execution.context.check!
        execution.writer.check!
        completion_transition = completion_transition(current, frontier, execution)
        compiled.append_checkpoint(
          writer: execution.writer, thread: current.thread_id, namespace: current.namespace,
          expected_base_id: current.id, mode: :advance, execution_id: current.execution_id,
          state: candidate, status: frontier.empty? ? :completed : :running,
          logical_step: step.logical_step, frontier:, pending: {}.freeze, interrupts: [].freeze,
          resume_values: execution.resume_values, attempts: step.attempts, failure: nil,
          total_tasks: step.total_tasks, consumed_task_ids: step.tasks.map(&:id),
          request_transition: completion_transition
        )
      end

      def completion_transition(current, frontier, execution)
        return unless frontier.empty?

        @checkpoints.terminal_request_transition(
          execution.writer, request_id: execution.request_id, execution_id: current.execution_id,
                            action: :completed, graph_status: :completed
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

      def non_interactive_result(current, step, execution)
        node_failure = non_interactive_failure(step)
        failed = @checkpoints.append_failed_checkpoint(
          current, **barrier_keywords(step, execution), errors: [node_failure]
        )
        RunResult.new(status: :failed, snapshot: compiled.snapshot(failed),
                      interrupts: step.interruptions, errors: [node_failure].freeze)
      end

      def non_interactive_failure(step)
        first = step.interruptions.first
        interrupted_task = step.tasks.find { |task| task.id == first.task_id }
        node = interrupted_task ? interrupted_task.node : first.task_id
        error = InterruptInNonInteractiveEpisodeError.new(
          "graph #{compiled.name} node interrupted in non-interactive episode",
          task_id: first.task_id, descriptor: first.descriptor
        )
        NodeError.new(error.message, graph_name: compiled.name, node:, task_id: first.task_id,
                                     attempt_id: nil, original: error)
      end

      private_constant :Execution, :Step
    end

    private_constant :Executor
  end
end
