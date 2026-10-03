# frozen_string_literal: true

module Tamoz
  module Graph
    # Classifies task results before a graph barrier commits.
    class SuperstepResults
      def initialize(compiled)
        @compiled = compiled
      end

      def classify(tasks, results)
        successes = {}
        interruptions = []
        errors = []
        pool_cancelled = false
        results.each_with_index do |result, index|
          task = tasks.fetch(index)
          pool_cancelled = classify_result(task, result, successes, interruptions, errors) || pool_cancelled
        end
        [successes.freeze, interruptions.sort_by(&:key).freeze, errors.freeze, pool_cancelled]
      end

      private

      attr_reader :compiled

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

      def interrupt_for(task, result)
        descriptor = result.descriptor
        unless descriptor.fetch('task_id') == task.id
          raise CheckpointConflictError, 'interrupt task identity is stale or mismatched'
        end

        Interrupt.new(
          task_id: descriptor.fetch('task_id'),
          call_index: descriptor.fetch('call_index'),
          descriptor: descriptor.fetch('descriptor')
        )
      end

      def classify_result(task, result, successes, interruptions, errors)
        case result
        when TaskResult::Succeeded
          successes[task.id] = result.value
        when TaskResult::Fatal
          raise result.error
        when TaskResult::Interrupted
          interruptions << interrupt_for(task, result)
        when TaskResult::Failed
          errors << node_error(task, result.error)
        when TaskResult::Cancelled, TaskResult::Stuck
          return true
        else
          raise PoolWorkerError, "unknown pool result #{result.class}"
        end
        false
      end
    end

    private_constant :SuperstepResults
  end
end
