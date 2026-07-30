# frozen_string_literal: true

module Tamoz
  module Graph
    class Limits
      MAX_STEPS = 1_000_000
      MAX_TASKS_PER_STEP = 65_536
      MAX_TOTAL_TASKS = 1_000_000
      MAX_PENDING_BYTES = 64 * 1024 * 1024
      MAX_HISTORY_LIMIT = 100_000

      attr_reader :max_steps, :max_tasks_per_step, :max_total_tasks, :max_pending_bytes,
                  :history_limit

      def initialize(
        max_steps: Tamoz.configuration.recursion_limit,
        max_tasks_per_step: 10_000,
        max_total_tasks: 100_000,
        max_pending_bytes: 4 * 1024 * 1024,
        history_limit: 1_000
      )
        @max_steps = bounded(max_steps, :max_steps, MAX_STEPS)
        @max_tasks_per_step = bounded(
          max_tasks_per_step,
          :max_tasks_per_step,
          MAX_TASKS_PER_STEP
        )
        @max_total_tasks = bounded(max_total_tasks, :max_total_tasks, MAX_TOTAL_TASKS)
        @max_pending_bytes = bounded(max_pending_bytes, :max_pending_bytes, MAX_PENDING_BYTES)
        @history_limit = bounded(history_limit, :history_limit, MAX_HISTORY_LIMIT)
        freeze
      end

      private

      def bounded(value, name, maximum)
        return value if value.is_a?(Integer) && value.positive? && value <= maximum

        raise ConfigurationError, "#{name} must be between 1 and #{maximum}"
      end
    end
  end
end
