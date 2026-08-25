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

    class Base
      attr_reader :max_tasks

      def initialize(max_tasks:, cancellation:)
        unless max_tasks.is_a?(Integer) && max_tasks.positive? && max_tasks <= MAX_TASKS
          raise ConfigurationError, "max_tasks must be between 1 and #{MAX_TASKS}"
        end
        if cancellation &&
           !(cancellation.respond_to?(:cancelled?) && cancellation.respond_to?(:reason))
          raise ConfigurationError, "pool cancellation token is invalid"
        end

        @max_tasks = max_tasks
        @default_cancellation = cancellation
      end

      private

      def cancellation_for(override)
        override || @default_cancellation || CancellationToken.new
      end

      def bounded_items(items)
        unless items.respond_to?(:each)
          raise ConfigurationError, "pool input must be enumerable"
        end

        result = []
        items.each do |item|
          if result.length >= max_tasks
            raise ConfigurationError, "pool input exceeds #{max_tasks} tasks"
          end
          result << item
        end
        result.freeze
      end

      def execute(index, item, cancellation, block)
        return cancelled_result(index, cancellation) if cancellation.cancelled?

        outcome = catch(:tamoz_interrupt) do
          begin
            [NORMAL_RESULT, block.call(item)]
          rescue StandardError => error
            if error.is_a?(FatalRuntimeFailure)
              return TaskResult::Fatal.new(index:, error:)
            end

            return TaskResult::Failed.new(index:, error:)
          end
        end

        return cancelled_result(index, cancellation) if cancellation.cancelled?

        if outcome.is_a?(Array) && outcome.length == 2 && outcome.first.equal?(NORMAL_RESULT)
          TaskResult::Succeeded.new(index:, value: outcome.fetch(1))
        else
          TaskResult::Interrupted.new(index:, descriptor: outcome)
        end
      end

      def cancelled_result(index, cancellation)
        TaskResult::Cancelled.new(
          index:,
          reason: cancellation.reason || "cancelled"
        )
      end
    end

    class Inline < Base
      def map(items, cancellation: nil, &block)
        raise ArgumentError, "a pool block is required" unless block

        token = cancellation_for(cancellation)
        bounded_items(items).each_with_index.map do |item, index|
          execute(index, item, token, block)
        end.freeze
      end
    end

    class Threads < Base
      attr_reader :size, :queue_capacity, :cancellation_grace, :stuck_worker_limit

      def initialize(
        size:,
        queue_capacity:,
        max_tasks:,
        cancellation:,
        cancellation_grace:,
        stuck_worker_limit:
      )
        super(max_tasks:, cancellation:)
        validate_size!(size)
        validate_queue_capacity!(queue_capacity)
        validate_cancellation_grace!(cancellation_grace)
        validate_stuck_worker_limit!(size:, limit: stuck_worker_limit)

        @size = size
        @queue_capacity = queue_capacity
        @cancellation_grace = cancellation_grace
        @stuck_worker_limit = stuck_worker_limit
        @state_mutex = Mutex.new
        @stuck_workers = 0
        @circuit_open = false
      end

      def map(items, cancellation: nil, &block)
        raise ArgumentError, "a pool block is required" unless block
        ensure_circuit_closed!

        values = bounded_items(items)
        return [].freeze if values.empty?

        token = cancellation_for(cancellation)
        return cancelled_values(values, token) if token.cancelled?

        execute_threads(values, token, block)
      end

      def circuit_open?
        @state_mutex.synchronize { @circuit_open }
      end

      def stuck_workers
        @state_mutex.synchronize { @stuck_workers }
      end

      private

      def validate_size!(size)
        return if size.is_a?(Integer) && size.positive? && size <= Configuration::MAX_POOL_SIZE

        raise ConfigurationError,
              "thread pool size must be between 1 and #{Configuration::MAX_POOL_SIZE}"
      end

      def validate_queue_capacity!(capacity)
        return if capacity.is_a?(Integer) && capacity.positive? && capacity <= MAX_QUEUE_CAPACITY

        raise ConfigurationError,
              "queue_capacity must be between 1 and #{MAX_QUEUE_CAPACITY}"
      end

      def validate_cancellation_grace!(grace)
        return if grace.is_a?(Numeric) && grace.finite? && !grace.negative? && grace <= 60

        raise ConfigurationError, "cancellation_grace must be between 0 and 60 seconds"
      end

      def validate_stuck_worker_limit!(size:, limit:)
        return if limit.is_a?(Integer) && limit.positive? && limit <= size

        raise ConfigurationError, "stuck_worker_limit must be between 1 and pool size"
      end

      def execute_threads(values, token, block)
        work = SizedQueue.new(queue_capacity)
        results = Queue.new
        active = {}
        active_mutex = Mutex.new
        workers = build_workers(
          [size, values.length].min,
          work:,
          results:,
          active:,
          active_mutex:,
          cancellation: token,
          block:
        )
        subscription = token.on_cancel { work.close unless work.closed? }
        submitted = submit(values, work, token)
        work.close unless work.closed?

        collected, fatal, completed_normally = collect(
          expected: values.length,
          submitted:,
          workers:,
          results:,
          active:,
          active_mutex:,
          cancellation: token
        )
        if completed_normally
          workers.each(&:join)
        else
          Concurrency.join_all(workers, deadline: cancellation_grace)
        end
        raise fatal if fatal

        values.each_index.map do |index|
          collected.fetch(index) do
            TaskResult::Cancelled.new(
              index:,
              reason: token.reason || "not_scheduled"
            )
          end
        end.freeze
      ensure
        subscription&.unsubscribe
        work&.close unless work&.closed?
        workers&.each { |worker| worker.join(0) }
      end

      def build_workers(count, work:, results:, active:, active_mutex:, cancellation:, block:)
        count.times.map do |worker_index|
          Thread.new do
            Thread.current.name = "tamoz-pool-#{worker_index}" if Thread.current.respond_to?(:name=)
            Thread.current.report_on_exception = false
            current_index = nil
            begin
              while (job = work.pop)
                current_index, item = job
                active_mutex.synchronize do
                  active[Thread.current.object_id] = [current_index, Thread.current.name || "tamoz-pool"]
                end
                result = execute(current_index, item, cancellation, block)
                results << [:result, current_index, result]
                active_mutex.synchronize { active.delete(Thread.current.object_id) }
                current_index = nil
              end
            rescue Exception => error # rubocop:disable Lint/RescueException
              results << [:fatal, current_index, error]
              cancellation.cancel!("pool_worker_failure")
            ensure
              active_mutex.synchronize { active.delete(Thread.current.object_id) }
            end
          end
        end
      end

      def submit(values, work, cancellation)
        submitted = 0
        values.each_with_index do |item, index|
          break if cancellation.cancelled?

          work.push([index, item].freeze)
          submitted += 1
        rescue ClosedQueueError
          break
        end
        submitted
      end

      def collect(expected:, submitted:, workers:, results:, active:, active_mutex:, cancellation:)
        collected = {}
        fatal = nil
        cancellation_deadline = nil

        loop do
          fatal ||= drain_results(results, collected)
          break if fatal
          break if collected.length >= expected

          if cancellation.cancelled?
            cancellation_deadline ||= Clock.monotonic.now + cancellation_grace
            break if Clock.monotonic.now >= cancellation_deadline
          elsif workers.none?(&:alive?)
            break
          end

          sleep(POLL_INTERVAL_SECONDS)
        end

        if cancellation.cancelled? && cancellation_deadline
          remaining = cancellation_deadline - Clock.monotonic.now
          workers.each { |worker| worker.join([remaining, 0].max) if remaining.positive? }
        end
        fatal ||= drain_results(results, collected)
        completed_normally = fatal.nil? && collected.length >= expected

        active_jobs = active_mutex.synchronize { active.values.to_h }
        stuck_jobs = active_jobs.reject { |index, _worker_name| collected.key?(index) }
        stuck_jobs.each do |index, worker_name|
          collected[index] = TaskResult::Stuck.new(index:, worker_name:)
        end
        record_stuck(stuck_jobs.length)

        submitted.times do |index|
          next if collected.key?(index)

          collected[index] = TaskResult::Cancelled.new(
            index:,
            reason: cancellation.reason || "worker_unavailable"
          )
        end
        (submitted...expected).each do |index|
          collected[index] = TaskResult::Cancelled.new(
            index:,
            reason: cancellation.reason || "not_scheduled"
          )
        end

        [collected, fatal, completed_normally]
      end

      def drain_results(results, collected)
        fatal = nil
        loop do
          kind, index, value = results.pop(true)
          if kind == :fatal
            fatal ||= value
          else
            collected[index] = value
          end
        rescue ThreadError
          break
        end
        fatal
      end

      def record_stuck(count)
        return if count.zero?

        @state_mutex.synchronize do
          @stuck_workers += count
          @circuit_open = true if @stuck_workers >= stuck_worker_limit
        end
      end

      def ensure_circuit_closed!
        return unless circuit_open?

        raise PoolCircuitOpenError,
              "thread pool circuit is open after #{stuck_workers} stuck workers"
      end

      def cancelled_values(values, token)
        values.each_index.map do |index|
          TaskResult::Cancelled.new(index:, reason: token.reason || "cancelled")
        end.freeze
      end
    end

    private_constant :Base, :Inline, :Threads, :DEFAULT_MAX_TASKS, :MAX_TASKS,
                     :MAX_QUEUE_CAPACITY, :POLL_INTERVAL_SECONDS, :NORMAL_RESULT
  end
end
