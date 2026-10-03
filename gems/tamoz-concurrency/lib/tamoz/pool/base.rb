# frozen_string_literal: true

module Tamoz
  module Pool
    # What every pool shares: the task bound, the default cancellation, and how one task becomes a TaskResult.
    class Base
      attr_reader :max_tasks

      def initialize(max_tasks:, cancellation:)
        unless max_tasks.is_a?(Integer) && max_tasks.positive? && max_tasks <= MAX_TASKS
          raise ConfigurationError, "max_tasks must be between 1 and #{MAX_TASKS}"
        end
        if cancellation &&
           !(cancellation.respond_to?(:cancelled?) && cancellation.respond_to?(:reason))
          raise ConfigurationError, 'pool cancellation token is invalid'
        end

        @max_tasks = max_tasks
        @default_cancellation = cancellation
      end

      private

      def cancellation_for(override)
        override || @default_cancellation || CancellationToken.new
      end

      def bounded_items(items)
        raise ConfigurationError, 'pool input must be enumerable' unless items.respond_to?(:each)

        result = []
        items.each do |item|
          raise ConfigurationError, "pool input exceeds #{max_tasks} tasks" if result.length >= max_tasks

          result << item
        end
        result.freeze
      end

      def execute(index, item, cancellation, block)
        return cancelled_result(index, cancellation) if cancellation.cancelled?

        outcome = catch(:tamoz_interrupt) do
          [NORMAL_RESULT, block.call(item)]
        rescue StandardError => e
          return failed_result(index, e)
        end
        return cancelled_result(index, cancellation) if cancellation.cancelled?

        completed_result(index, outcome)
      end

      def failed_result(index, error)
        return TaskResult::Fatal.new(index:, error:) if error.is_a?(FatalRuntimeFailure)

        TaskResult::Failed.new(index:, error:)
      end

      def completed_result(index, outcome)
        if outcome.is_a?(Array) && outcome.length == 2 && outcome.first.equal?(NORMAL_RESULT)
          TaskResult::Succeeded.new(index:, value: outcome.fetch(1))
        else
          TaskResult::Interrupted.new(index:, descriptor: outcome)
        end
      end

      def cancelled_result(index, cancellation)
        TaskResult::Cancelled.new(index:, reason: cancellation.reason || 'cancelled')
      end
    end

    private_constant :Base
  end
end
