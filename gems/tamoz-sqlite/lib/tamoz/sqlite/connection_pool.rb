# frozen_string_literal: true

module Tamoz
  module SQLite
    class ConnectionPool
      attr_reader :path, :limits, :pid

      def initialize(path:, limits:)
        @path = String(path).dup.freeze
        @limits = limits
        @pid = Process.pid
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @available = []
        @checked_out = 0
        @closed = false
        limits.pool_size.times { @available << self.class.open(path, limits:) }
      rescue Exception # rubocop:disable Lint/RescueException
        @available&.each { |connection| connection.close unless connection.closed? }
        raise
      end

      def self.open(path, limits:, initialize_wal: false)
        database = ::SQLite3::Database.new(
          path,
          readwrite: true,
          strict: true,
          results_as_hash: false,
          default_transaction_mode: :immediate
        )
        database.busy_timeout = (limits.busy_timeout * 1_000).ceil
        database.execute("PRAGMA foreign_keys = ON")
        database.execute("PRAGMA trusted_schema = OFF")
        database.execute("PRAGMA recursive_triggers = ON")
        database.execute("PRAGMA synchronous = FULL")
        database.execute(
          "PRAGMA wal_autocheckpoint = #{Integer(limits.wal_autocheckpoint_pages)}"
        )
        database.execute("PRAGMA journal_mode = WAL") if initialize_wal
        foreign_keys = database.get_first_value("PRAGMA foreign_keys")
        synchronous = database.get_first_value("PRAGMA synchronous")
        journal_mode = database.get_first_value("PRAGMA journal_mode")
        unless foreign_keys == 1 &&
               synchronous == 2 &&
               journal_mode.to_s.downcase == "wal"
          raise ConfigurationError, "SQLite safety pragmas were not applied"
        end

        database
      rescue Exception # rubocop:disable Lint/RescueException
        database&.close unless database&.closed?
        raise
      end

      def with_connection(deadline: monotonic_now + limits.checkout_timeout)
        connection = checkout(deadline:)
        yield connection
      ensure
        checkin(connection) if connection
      end

      def close
        connections = @mutex.synchronize do
          ensure_process!
          return false if @closed

          @closed = true
          values = @available
          @available = []
          @condition.broadcast
          values
        end
        connections.each { |connection| connection.close unless connection.closed? }
        true
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def stats
        @mutex.synchronize do
          {
            "size" => limits.pool_size,
            "available" => @available.length,
            "checked_out" => @checked_out,
            "closed" => @closed
          }.freeze
        end
      end

      private

      def checkout(deadline:)
        @mutex.synchronize do
          ensure_process!
          loop do
            raise ClosedError, "SQLite connection pool is closed" if @closed
            unless @available.empty?
              @checked_out += 1
              return @available.pop
            end

            remaining = deadline - monotonic_now
            if remaining <= 0
              raise BusyError, "SQLite connection checkout timed out"
            end
            @condition.wait(@mutex, remaining)
          end
        end
      end

      def checkin(connection)
        should_close = @mutex.synchronize do
          @checked_out -= 1
          if @closed || Process.pid != pid
            true
          else
            @available << connection
            @condition.signal
            false
          end
        end
        connection.close if should_close && !connection.closed?
      end

      def ensure_process!
        return if Process.pid == pid

        raise ClosedError,
              "SQLite adapter cannot be reused after fork; construct one in the child"
      end

      def monotonic_now
        Tamoz::Clock.monotonic.now
      end
    end
  end
end
