# frozen_string_literal: true

module Tamoz
  module SQLite
    LeaseRecord = Data.define(
      :thread_id,
      :namespace,
      :owner_id,
      :fence,
      :expires_at_ms,
      :ttl
    )

    class LeaseGuard
      attr_reader :adapter

      def initialize(adapter:, lease:)
        @adapter = adapter
        @lease = lease
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @stopping = false
        @error = nil
        @thread = nil
      end

      def start
        @mutex.synchronize do
          raise ConfigurationError, "lease guard already started" if @thread

          @thread = Thread.new { renewal_loop }
          @thread.name = "tamoz-sqlite-lease-renewal" if @thread.respond_to?(:name=)
          @thread.report_on_exception = false
        end
        self
      end

      def lease
        @mutex.synchronize { @lease }
      end

      def check!
        error = @mutex.synchronize { @error }
        raise error if error

        current = adapter.__send__(:validate_lease, lease)
        @mutex.synchronize { @lease = current }
        true
      rescue FatalRuntimeFailure => error
        @mutex.synchronize { @error ||= error }
        raise
      end

      def close
        thread = @mutex.synchronize do
          return false if @stopping

          @stopping = true
          @condition.broadcast
          @thread
        end
        thread&.join(adapter.limits.operation_timeout + 0.1)
        unless !thread || !thread.alive?
          raise ClosedError, "lease renewal worker did not stop"
        end

        adapter.__send__(:release_lease, lease)
        true
      end

      private

      def renewal_loop
        interval = [lease.ttl / 3.0, 0.01].max
        loop do
          stop = @mutex.synchronize do
            @condition.wait(@mutex, interval) unless @stopping
            @stopping
          end
          break if stop

          renewed = adapter.__send__(:renew_lease, lease)
          @mutex.synchronize { @lease = renewed }
        rescue FatalRuntimeFailure => error
          @mutex.synchronize do
            @error ||= error
            @stopping = true
          end
          break
        end
      end
    end

    private_constant :LeaseRecord, :LeaseGuard
  end
end
