# frozen_string_literal: true

module Tamoz
  module SQLite
    class DatabaseKernel
      BEGIN_SQL = {
        deferred: "BEGIN DEFERRED",
        immediate: "BEGIN IMMEDIATE",
        exclusive: "BEGIN EXCLUSIVE"
      }.freeze

      attr_reader :pool, :limits, :fault_injector

      def initialize(pool:, limits:, fault_injector:)
        unless fault_injector.respond_to?(:call)
          raise ConfigurationError, "fault_injector must respond to call"
        end

        @pool = pool
        @limits = limits
        @fault_injector = fault_injector
      end

      def transaction(operation:, mode: :immediate)
        begin_sql = BEGIN_SQL.fetch(mode) do
          raise ConfigurationError, "unknown SQLite transaction mode #{mode.inspect}"
        end
        deadline = monotonic_now + limits.operation_timeout
        attempt = 0

        begin
          attempt += 1
          pool.with_connection(deadline:) do |connection|
            begin
              inject(:before_begin, operation, attempt)
              connection.execute(begin_sql)
              inject(:after_begin, operation, attempt)
              tx = Transaction.new(
                connection:,
                operation:,
                attempt:,
                fault_injector:
              )
              result = yield tx
              inject(:before_commit, operation, attempt)
              connection.execute("COMMIT")
              inject(:after_commit, operation, attempt)
              return result
            rescue Exception # rubocop:disable Lint/RescueException
              rollback(connection)
              raise
            end
          end
        rescue ::SQLite3::BusyException, ::SQLite3::LockedException => error
          if attempt <= limits.retry_limit
            remaining = deadline - monotonic_now
            delay = retry_delay(attempt)
            if remaining > delay
              sleep(delay) if delay.positive?
              retry
            end
          end
          ExceptionMapper.raise_mapped(error, operation:)
        rescue ::SQLite3::Exception => error
          ExceptionMapper.raise_mapped(error, operation:)
        end
      end

      def read(operation:)
        deadline = monotonic_now + limits.operation_timeout
        pool.with_connection(deadline:) do |connection|
          transaction = Transaction.new(
            connection:,
            operation:,
            attempt: nil,
            fault_injector:
          )
          yield transaction
        end
      rescue ::SQLite3::Exception => error
        ExceptionMapper.raise_mapped(error, operation:)
      end

      private

      def rollback(connection)
        connection.execute("ROLLBACK") if connection.transaction_active?
      rescue ::SQLite3::Exception
        nil
      end

      def retry_delay(attempt)
        base = limits.retry_base_delay * (2**(attempt - 1))
        bounded = [base, 0.25].min
        bounded * (0.75 + Random.rand * 0.5)
      end

      def inject(point, operation, attempt)
        fault_injector.call(
          point,
          FaultHook.transaction(operation:, attempt:)
        )
      end

      def monotonic_now
        Tamoz::Clock.monotonic.now
      end

      private_constant :BEGIN_SQL
    end
  end
end
