# frozen_string_literal: true

module Tamoz
  module Pool
    # One Threads#map call: feeds the workers, collects their results, and accounts for stuck or unscheduled tasks.
    class ThreadRun
      def initialize(limits, values, token, task:, on_stuck:)
        @limits = limits
        @values = values
        @token = token
        @task = task
        @on_stuck = on_stuck
        @work = SizedQueue.new(limits.queue_capacity)
        @results = Queue.new
        @active = {}.compare_by_identity
        @active_mutex = Mutex.new
        @collected = {}
      end

      def call
        @workers = start_workers([@limits.size, @values.length].min)
        subscription = @token.on_cancel { close_work }
        submitted = submit
        close_work
        fatal, completed_normally = collect(submitted)
        join_workers(completed_normally)
        raise fatal if fatal

        ordered_results
      ensure
        subscription&.unsubscribe
        close_work
        @workers&.each { |worker| worker.join(0) }
      end

      private

      def start_workers(count)
        Array.new(count) do |worker_index|
          Thread.new do
            name_thread(worker_index)
            work_loop
          end
        end
      end

      def name_thread(worker_index)
        Thread.current.name = "tamoz-pool-#{worker_index}" if Thread.current.respond_to?(:name=)
        Thread.current.report_on_exception = false
      end

      def work_loop
        current_index = nil
        while (job = @work.pop)
          current_index, item = job
          mark_active(current_index)
          @results << [:result, current_index, @task.call(current_index, item)]
          clear_active
          current_index = nil
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        @results << [:fatal, current_index, e]
        @token.cancel!('pool_worker_failure')
      ensure
        clear_active
      end

      def mark_active(index)
        @active_mutex.synchronize { @active[Thread.current] = [index, Thread.current.name || 'tamoz-pool'] }
      end

      def clear_active
        @active_mutex.synchronize { @active.delete(Thread.current) }
      end

      def submit
        submitted = 0
        @values.each_with_index do |item, index|
          break if @token.cancelled?

          @work.push([index, item].freeze)
          submitted += 1
        rescue ClosedQueueError
          break
        end
        submitted
      end

      def close_work
        @work.close unless @work.closed?
      end

      def collect(submitted)
        fatal, deadline = await_results
        join_within_grace(deadline)
        fatal ||= drain_results
        completed_normally = fatal.nil? && @collected.length >= @values.length
        mark_stuck_jobs
        mark_unfinished(submitted)
        [fatal, completed_normally]
      end

      def await_results
        deadline = nil
        loop do
          fatal = drain_results
          return [fatal, deadline] if fatal || @collected.length >= @values.length

          cancelled = @token.cancelled?
          deadline ||= Clock.monotonic.now + @limits.cancellation_grace if cancelled
          return [nil, deadline] if stop_waiting?(cancelled, deadline)

          sleep(POLL_INTERVAL_SECONDS)
        end
      end

      def stop_waiting?(cancelled, deadline)
        cancelled ? Clock.monotonic.now >= deadline : @workers.none?(&:alive?)
      end

      def join_within_grace(deadline)
        return unless @token.cancelled? && deadline

        remaining = deadline - Clock.monotonic.now
        @workers.each { |worker| worker.join([remaining, 0].max) if remaining.positive? }
      end

      def drain_results
        fatal = nil
        loop do
          kind, index, value = @results.pop(true)
          if kind == :fatal
            fatal ||= value
          else
            @collected[index] = value
          end
        rescue ThreadError
          break
        end
        fatal
      end

      def mark_stuck_jobs
        active_jobs = @active_mutex.synchronize { @active.values.to_h }
        stuck_jobs = active_jobs.reject { |index, _worker_name| @collected.key?(index) }
        stuck_jobs.each { |index, worker_name| @collected[index] = TaskResult::Stuck.new(index:, worker_name:) }
        @on_stuck.call(stuck_jobs.length)
      end

      def mark_unfinished(submitted)
        submitted.times do |index|
          @collected[index] = cancelled(index, 'worker_unavailable') unless @collected.key?(index)
        end
        (submitted...@values.length).each { |index| @collected[index] = cancelled(index, 'not_scheduled') }
      end

      def join_workers(completed_normally)
        if completed_normally
          @workers.each(&:join)
        else
          Concurrency.join_all(@workers, deadline: @limits.cancellation_grace)
        end
      end

      def ordered_results
        @values.each_index.map do |index|
          @collected.fetch(index) { cancelled(index, 'not_scheduled') }
        end.freeze
      end

      def cancelled(index, fallback_reason)
        TaskResult::Cancelled.new(index:, reason: @token.reason || fallback_reason)
      end
    end

    private_constant :ThreadRun
  end
end
