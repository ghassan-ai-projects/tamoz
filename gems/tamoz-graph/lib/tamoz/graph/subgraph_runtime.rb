# frozen_string_literal: true

module Tamoz
  module Graph
    class SubgraphRuntime
      attr_reader :parent, :checkpoint, :task, :concurrency

      def initialize(parent:, checkpoint:, task:, concurrency:)
        @parent = parent
        @checkpoint = checkpoint
        @task = task
        @concurrency = concurrency
        @call_mutex = Mutex.new
        @call_index = 0
      end

      def call(child, input, context)
        unless child.is_a?(Compiled)
          raise ConfigurationError, "graph runtime can invoke only a compiled graph"
        end

        bound = child.__send__(:with_checkpointer, parent.checkpointer)
        call_index = next_call_index
        namespace = child_namespace(child, call_index)
        child_context = context.child(
          "subgraph.#{child.name}",
          task_id: context.task_id,
          run_id: child_execution_id(child, call_index)
        )
        loop do
          latest = parent.checkpointer.latest(
            thread_id: checkpoint.thread_id,
            namespace:
          )
          return child_output(child, latest.state) if latest&.status == :completed

          result = run_child(
            bound,
            latest,
            child_input(child, input),
            child_context,
            namespace,
            call_index
          )
          return child_output(child, result.state) if result.completed?
          next if result.paused?

          if result.failed?
            raise(result.errors.first || failed_child_error(child, result))
          end
          context.check!
          raise CancelledError, "subgraph execution was cancelled"
        end
      end

      private

      def run_child(child, latest, input, context, namespace, call_index)
        if latest.nil?
          return child.__send__(
            :invoke_at,
            input,
            thread: checkpoint.thread_id,
            namespace:,
            request_id: context.request_id,
            execution_id: child_execution_id(child, call_index),
            concurrency:,
            new_execution: false,
            context:
          )
        end

        child.__send__(:compatible!, latest)
        case latest.status
        when :paused
          answer = Tamoz.interrupt(interrupt_descriptor(child, latest), context)
          child.__send__(
            :resume_at,
            resume_answers(latest, answer),
            thread: checkpoint.thread_id,
            namespace:,
            request_id: context.request_id,
            concurrency:,
            context:
          )
        when :failed
          child.__send__(
            :retry_failed_at,
            thread: checkpoint.thread_id,
            namespace:,
            request_id: context.request_id,
            concurrency:,
            context:
          )
        when :running
          child.__send__(
            :continue_at,
            thread: checkpoint.thread_id,
            namespace:,
            request_id: context.request_id,
            concurrency:,
            context:
          )
        else
          raise CheckpointConflictError,
                "subgraph checkpoint has unsupported status #{latest.status.inspect}"
        end
      end

      def child_namespace(child, call_index)
        [
          *checkpoint.namespace,
          "subgraph",
          task.id.delete_prefix("sha256:"),
          call_index.to_s,
          child.name,
          child.definition_digest.delete_prefix("sha256:")[0, 16]
        ].freeze
      end

      def child_execution_id(child, call_index)
        Canonical.digest(
          {
            "parent_execution_id" => checkpoint.execution_id,
            "parent_task_id" => task.id,
            "call_index" => call_index,
            "child_definition_digest" => child.definition_digest
          },
          domain: "tamoz.graph.subgraph.execution\n"
        )
      end

      def next_call_index
        @call_mutex.synchronize do
          current = @call_index
          @call_index += 1
          current
        end
      end

      def child_input(child, input)
        return input unless input.is_a?(Hash)

        allowed = child.channels.keys.map(&:to_s)
        input.each_with_object({}) do |(key, value), result|
          result[key] = value if allowed.include?(key.to_s)
        end.freeze
      end

      def child_output(child, state)
        state.reject do |name, _value|
          child.channels.fetch(name).managed?
        end.freeze
      end

      def interrupt_descriptor(child, latest)
        {
          "kind" => "subgraph",
          "graph" => child.name,
          "namespace" => latest.namespace,
          "interrupts" => latest.interrupts.map do |interrupt|
            {
              "task_id" => interrupt.task_id,
              "call_index" => interrupt.call_index,
              "descriptor" => interrupt.descriptor
            }
          end
        }
      end

      def resume_answers(latest, answer)
        if latest.interrupts.one?
          interrupt = latest.interrupts.first
          return {
            interrupt.task_id => {interrupt.call_index => answer}
          }
        end
        unless answer.is_a?(Hash)
          raise InvalidUpdateError,
                "parallel subgraph interrupts require task/call-index answers"
        end

        answer
      end

      def failed_child_error(child, result)
        original = CheckpointError.new("subgraph failed without an immediate error")
        NodeError.new(
          "subgraph #{child.name} failed",
          graph_name: child.name,
          original:
        )
      end
    end

    private_constant :SubgraphRuntime
  end
end
