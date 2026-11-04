# frozen_string_literal: true

module Tamoz
  module Graph
    # Executes scheduled nodes and persists their pending writes.
    class TaskExecution
      def initialize(compiled)
        @compiled = compiled
      end

      def execute_tasks(tasks, checkpoint, execution)
        return [] if tasks.empty?

        context = execution.context
        concurrency = execution.concurrency
        pool = compiled.pool_for(concurrency)
        pool.map(tasks, cancellation: context.cancellation) do |task|
          resumed = execution.resume_values.fetch(task.id, {}.freeze)
          task_context = task_context_for(task, checkpoint, context, concurrency, resumed)
          execute_task(task, checkpoint, task_context, execution.writer)
        end
      end

      private

      attr_reader :compiled

      def task_context_for(task, checkpoint, context, concurrency, resume_values)
        cursor = InterruptCursor.new(task_id: task.id, resume_values:)
        context.with(
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
      end

      def execute_task(task, checkpoint, task_context, writer)
        emit_task_start(task_context, task)
        outcome = invoke_node(task, checkpoint, task_context)
        emit_task_end(task_context, task)
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
                  'node Command may contain only update and goto in M2'
          end
          [compiled.state_manager.normalize_update(value.update), value.goto]
        else
          raise InvalidUpdateError,
                "node must return nil, Hash, or Tamoz::Command; got #{value.class}"
        end
      end

      def emit_task_start(task_context, task)
        task_context.emit(
          :task_start,
          {
            'graph' => compiled.name,
            'node' => task.node.to_s,
            'attempt' => task.attempt
          }
        )
      end

      def emit_task_end(task_context, task)
        task_context.emit(
          :task_end,
          {
            'graph' => compiled.name,
            'node' => task.node.to_s,
            'status' => 'succeeded'
          }
        )
      end
    end

    private_constant :TaskExecution
  end
end
