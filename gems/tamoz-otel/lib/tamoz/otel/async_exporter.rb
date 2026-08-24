# frozen_string_literal: true

module Tamoz
  module OTel
    # Bounded async export over the shared Concurrency::Drain skeleton. What
    # stays here is exactly this exporter's own policy: drop accounting per
    # refusal reason, exponential delivery backoff, and the failure-limit
    # disable.
    class AsyncExporter < Concurrency::Drain
      def initialize(exporter:, max_queue: 1_024, batch_size: 256, failure_limit: 5, interval_ms: 200)
        @exporter = exporter
        positive_integer(max_queue, :max_queue)
        positive_integer(batch_size, :batch_size)
        @failure_limit = positive_integer(failure_limit, :failure_limit)
        interval_ms = Float(interval_ms)
        unless interval_ms.finite? && interval_ms.between?(1, 60_000)
          raise Tamoz::Observability::ValidationError, 'interval_ms must be between 1 and 60000'
        end
        @interval = interval_ms / 1_000
        @drops = Hash.new(0)
        @failures = 0
        @next_attempt_at = 0.0
        super(lanes: { export: max_queue }, batch_size:, interval: @interval)
      end

      def open(descriptor = {}, credential = nil)
        return :opened unless @exporter.respond_to?(:open)

        credential.nil? ? @exporter.open(descriptor) : @exporter.open(descriptor, credential)
      rescue StandardError
        :rejected
      end

      def record(signal)
        synchronize do
          if drain_closed? || drain_disabled?
            @drops[drain_closed? ? 'closed' : 'disabled'] += 1
            next :dropped
          end
          if accept(:export, signal)
            :recorded
          else
            @drops['queue_full'] += 1
            :dropped
          end
        end
      end

      def health
        synchronize do
          {
            'queue_depth' => lane_depths.values.sum,
            'drops' => @drops.dup,
            'failures' => @failures,
            'disabled' => drain_disabled?
          }
        end
      end

      private

      def due?(now)
        now >= @next_attempt_at
      end

      def wait_timeout(now)
        [@interval, @next_attempt_at - now].select(&:positive?).min
      end

      def compose_batch
        shift_lane(:export, batch_size)
      end

      def deliver_batch(batch)
        @exporter.export(batch, deadline_ms: 2_000)
      end

      # Runs on the drain thread outside the lock; health() reads these under
      # the mutex, so the accounting stays inside synchronize as before.
      def delivery_result(result, batch)
        @mutex.synchronize { account_delivery(result, batch) }
        disable_drain! if result != :delivered && @failures >= @failure_limit
      end

      def account_delivery(result, batch)
        case result
        when :delivered
          @failures = 0
          @next_attempt_at = 0.0
        else
          @failures += 1
          @drops[result.to_s] += batch.length
          delay = [@interval * (2**([@failures - 1, 8].min)), 30.0].min
          @next_attempt_at = monotonic_now + delay
        end
      end

      def handle_loop_error(_error)
        disable_drain!
      end

      def on_thread_exit
        @exporter.close(deadline_ms: 0) if closed? && @exporter.respond_to?(:close)
      end

      def positive_integer(value, name)
        return value if value.is_a?(Integer) && value.positive?

        raise Tamoz::Observability::ValidationError, "#{name} must be positive"
      end
    end
  end
end
