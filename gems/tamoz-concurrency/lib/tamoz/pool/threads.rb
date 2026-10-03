# frozen_string_literal: true

module Tamoz
  module Pool
    # A bounded thread pool whose circuit opens once too many workers are stuck.
    class Threads < Base
      def initialize(max_tasks:, cancellation:, **limits)
        super(max_tasks:, cancellation:)
        @limits = ThreadLimits.new(**limits)
        @state_mutex = Mutex.new
        @stuck_workers = 0
        @circuit_open = false
      end

      def map(items, cancellation: nil, &block)
        raise ArgumentError, 'a pool block is required' unless block

        ensure_circuit_closed!

        values = bounded_items(items)
        return [].freeze if values.empty?

        token = cancellation_for(cancellation)
        return cancelled_values(values, token) if token.cancelled?

        task = ->(index, item) { execute(index, item, token, block) }
        ThreadRun.new(@limits, values, token, task:, on_stuck: method(:record_stuck)).call
      end

      def size = @limits.size
      def queue_capacity = @limits.queue_capacity
      def cancellation_grace = @limits.cancellation_grace
      def stuck_worker_limit = @limits.stuck_worker_limit

      def circuit_open?
        @state_mutex.synchronize { @circuit_open }
      end

      def stuck_workers
        @state_mutex.synchronize { @stuck_workers }
      end

      private

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
          TaskResult::Cancelled.new(index:, reason: token.reason || 'cancelled')
        end.freeze
      end
    end

    private_constant :Threads
  end
end
