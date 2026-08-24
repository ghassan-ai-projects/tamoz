# frozen_string_literal: true

module Tamoz
  module Concurrency
    # The bounded-buffer background drain skeleton that AsyncExporter and the
    # disk Journal re-implemented by hand: named bounded lanes, one mutex +
    # condition pair, a background thread, flush-with-deadline, and a
    # close-joins-thread-with-grace. Policy stays in subclasses via the
    # template methods (due?/wait_timeout/compose_batch/deliver_batch/
    # delivery_result/handle_loop_error/on_thread_exit); drop accounting and
    # delivery backoff are caller concerns, not shared here.
    class Drain
      def initialize(lanes:, batch_size:, interval: 0.2)
        limits = lanes.to_h { |lane, limit| [lane.to_sym, limit] }
        limits.each do |lane, limit|
          unless limit.is_a?(Integer) && limit.positive?
            raise ConfigurationError, "drain lane #{lane} limit must be a positive integer"
          end
        end
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ConfigurationError, "drain batch_size must be a positive integer"
        end
        unless interval.is_a?(Numeric) && interval.finite? && interval.positive?
          raise ConfigurationError, "drain interval must be a positive number"
        end

        @lanes = limits.freeze
        @batch_size = batch_size
        @interval = interval
        @queues = limits.keys.to_h { |lane| [lane, []] }
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @in_flight = 0
        @closed = false
        @disabled = false
        @thread = Thread.new { drain_loop }
      end

      # False when closed, disabled, or the lane is full — the caller owns the
      # drop accounting for each refusal reason.
      def push(lane, item)
        synchronize { accept(lane, item) }
      end

      def depths
        synchronize { @queues.transform_values(&:length) }
      end

      def in_flight
        synchronize { @in_flight }
      end

      def closed?
        synchronize { @closed }
      end

      def disabled?
        synchronize { @disabled }
      end

      # Waits until every lane is empty and nothing is being delivered, bounded
      # by the deadline. Returns the count that could not be drained.
      def flush(deadline_ms:)
        deadline = monotonic_now + Float(deadline_ms) / 1_000
        synchronize do
          while outstanding.positive?
            remaining = deadline - monotonic_now
            break if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
          outstanding
        end
      end

      # Broadcasts the stop and joins the drain thread within the grace.
      def close(deadline_ms: 1_000)
        synchronize do
          @closed = true
          @condition.broadcast
        end
        @thread.join(Float(deadline_ms) / 1_000)
        nil
      rescue StandardError
        nil
      end

      private

      attr_reader :batch_size

      # Callers of these helpers hold @mutex; none may re-enter the lock.
      def synchronize
        @mutex.synchronize { yield }
      end

      def accept(lane, item)
        return false if @closed || @disabled

        queue = @queues.fetch(lane.to_sym) do
          raise ConfigurationError, "unknown drain lane #{lane.inspect}"
        end
        return false if queue.length >= @lanes.fetch(lane.to_sym)

        queue << item
        @condition.signal
        true
      end

      def shift_lane(lane, count)
        queue = @queues.fetch(lane)
        queue.shift(count)
      end

      def lane_depths
        @queues.transform_values(&:length)
      end

      def drain_closed?
        @closed
      end

      def drain_disabled?
        @disabled
      end

      # Safe from inside or outside the drain thread's delivery path.
      def disable_drain!
        synchronize { @disabled = true }
        @condition.broadcast
      end

      def outstanding
        @queues.values.sum(&:length) + @in_flight
      end

      def monotonic_now
        Clock.monotonic.now
      end

      def take_batch
        batch = nil
        synchronize do
          while !@closed && (empty_lanes? || !due?(monotonic_now))
            @condition.wait(@mutex, wait_timeout(monotonic_now))
          end
          next if @closed && empty_lanes?

          candidate = compose_batch
          unless candidate.empty?
            @in_flight += candidate.length
            batch = candidate
          end
        end
        batch
      end

      def empty_lanes?
        @queues.values.all?(&:empty?)
      end

      def drain_loop
        loop do
          batch = take_batch
          break unless batch

          begin
            delivery_result(deliver_batch(batch), batch)
          rescue StandardError => error
            handle_loop_error(error)
            break
          ensure
            synchronize do
              @in_flight -= batch.length if batch
              @condition.broadcast
            end
          end
        end
      rescue StandardError => error
        handle_loop_error(error)
      ensure
        on_thread_exit
      end

      # --- template methods (policy lives in subclasses) --------------------

      # Backoff gate: false keeps the loop waiting even when lanes hold items.
      def due?(_now)
        true
      end

      # How long the idle wait may sleep before re-checking due?. The default
      # is the constructor interval.
      def wait_timeout(_now)
        @interval
      end

      # Default: shift up to batch_size items from each lane in declaration
      # order.
      def compose_batch
        @queues.keys.flat_map { |lane| shift_lane(lane, batch_size) }
      end

      def deliver_batch(_batch)
        raise NotImplementedError, "subclasses must deliver batches"
      end

      # Called after a successful deliver_batch with its outcome.
      def delivery_result(_outcome, _batch); end

      # A delivery or framework failure: mark the drain unhealthy. Returning
      # from this ends the drain thread.
      def handle_loop_error(error)
        raise error
      end

      def on_thread_exit; end
    end
  end
end
