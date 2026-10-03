# frozen_string_literal: true

module Tamoz
  module Pool
    DEFAULT_MAX_TASKS = 10_000
    MAX_TASKS = 1_000_000
    MAX_QUEUE_CAPACITY = 65_536
    POLL_INTERVAL_SECONDS = 0.001
    NORMAL_RESULT = Object.new.freeze

    module_function

    def for(
      mode,
      size: nil,
      queue_capacity: nil,
      max_tasks: DEFAULT_MAX_TASKS,
      cancellation: nil,
      cancellation_grace: 1.0,
      stuck_worker_limit: nil
    )
      case mode
      when :inline, "inline"
        Inline.new(max_tasks:, cancellation:)
      when :threads, "threads"
        actual_size = size || Tamoz.configuration.pool_size
        Threads.new(
          size: actual_size,
          queue_capacity: queue_capacity || actual_size * 2,
          max_tasks:,
          cancellation:,
          cancellation_grace:,
          stuck_worker_limit: stuck_worker_limit || actual_size
        )
      when :fibers, "fibers"
        raise ConfigurationError, "fiber pool is unsupported until its conformance suite passes"
      else
        raise ConfigurationError, "unknown pool mode #{mode.inspect}"
      end
    end

    private_constant :DEFAULT_MAX_TASKS, :MAX_TASKS, :MAX_QUEUE_CAPACITY, :POLL_INTERVAL_SECONDS, :NORMAL_RESULT
  end
end

require_relative "pool/base"
require_relative "pool/inline"
require_relative "pool/thread_limits"
require_relative "pool/threads"
require_relative "pool/thread_run"
