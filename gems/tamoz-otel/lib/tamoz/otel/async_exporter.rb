# frozen_string_literal: true

require 'thread'

module Tamoz
  module OTel
    class AsyncExporter
      def initialize(exporter:, max_queue: 1_024, batch_size: 256, failure_limit: 5, interval_ms: 200)
        @exporter = exporter
        @max_queue = positive_integer(max_queue, :max_queue)
        @batch_size = positive_integer(batch_size, :batch_size)
        @failure_limit = positive_integer(failure_limit, :failure_limit)
        interval_ms = Float(interval_ms)
        raise Tamoz::Observability::ValidationError, 'interval_ms must be between 1 and 60000' unless interval_ms.finite? && interval_ms.between?(1, 60_000)
        @interval = interval_ms / 1_000
        @queue = []
        @drops = Hash.new(0)
        @failures = 0
        @next_attempt_at = 0.0
        @disabled = false
        @closed = false
        @in_flight = 0
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @thread = Thread.new { run }
      end

      def open(descriptor = {}, credential = nil)
        return :opened unless @exporter.respond_to?(:open)

        credential.nil? ? @exporter.open(descriptor) : @exporter.open(descriptor, credential)
      rescue StandardError
        :rejected
      end

      def record(signal)
        @mutex.synchronize do
          if @closed || @disabled
            @drops[@closed ? 'closed' : 'disabled'] += 1
            return :dropped
          end
          if @queue.length >= @max_queue
            @drops['queue_full'] += 1
            return :dropped
          end

          @queue << signal
          @condition.signal
          :recorded
        end
      end

      def health
        @mutex.synchronize do
          {
            'queue_depth' => @queue.length,
            'drops' => @drops.dup,
            'failures' => @failures,
            'disabled' => @disabled
          }
        end
      end

      def flush(deadline_ms:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(deadline_ms) / 1_000
        @mutex.synchronize do
          while @queue.any? || @in_flight.positive?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            @condition.wait(@mutex, remaining)
          end
          @queue.length + @in_flight
        end
      end

      def close(deadline_ms: 1_000)
        @mutex.synchronize do
          @closed = true
          @condition.broadcast
        end
        @thread.join(Float(deadline_ms) / 1_000)
        nil
      rescue StandardError
        nil
      end

      private

      def positive_integer(value, name)
        return value if value.is_a?(Integer) && value.positive?
        raise Tamoz::Observability::ValidationError, "#{name} must be positive"
      end

      def run
        loop do
          batch = @mutex.synchronize do
            while !@closed && (@queue.empty? || monotonic_now < @next_attempt_at)
              remaining = @next_attempt_at - monotonic_now
              @condition.wait(@mutex, [@interval, remaining].select(&:positive?).min)
            end
            next if @closed && @queue.empty?
            batch = @queue.shift(@batch_size)
            @in_flight += batch.length
            batch
          end
          break unless batch
          deliver(batch)
        end
      rescue StandardError
        @mutex.synchronize { @disabled = true }
      ensure
        @exporter.close(deadline_ms: 0) if @closed && @exporter.respond_to?(:close)
      end

      def deliver(batch)
        result = @exporter.export(batch, deadline_ms: 2_000)
        @mutex.synchronize do
          if result == :delivered
            @failures = 0
            @next_attempt_at = 0.0
          else
            @failures += 1
            @drops[result.to_s] += batch.length
            delay = [@interval * (2**([@failures - 1, 8].min)), 30.0].min
            @next_attempt_at = monotonic_now + delay
            @disabled = true if @failures >= @failure_limit
          end
        end
      ensure
        @mutex.synchronize do
          @in_flight -= batch.length if batch
          @condition.broadcast
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
