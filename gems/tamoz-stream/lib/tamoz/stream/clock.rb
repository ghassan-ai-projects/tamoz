# frozen_string_literal: true

module Tamoz
  module Stream
    # The two injected clock modes (plan §5/C1):
    #
    # - WallClock: the runtime's live-mode clock (monotonic processing time;
    #   the stream tables NEVER call `backend_time` — this is the injected
    #   source of every stream-owned timestamp).
    # - ReplayClock: the harness's virtual clock. `advance(delta)` steps
    #   virtual time; replay re-executes the identical operator chain under the
    #   same virtual clock and produces byte-identical state.
    #
    # Both are monotonic: a backward step raises `StreamClockError`.
    class WallClock
      include StreamClock

      def initialize(now: nil)
        @epoch = now || Time.now.to_i
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last = @epoch
      end

      # Live-mode processing time: the epoch anchor plus the elapsed monotonic
      # time since construction, so the clock ADVANCES in live mode (the
      # idle-watermark mechanism depends on it — a frozen clock would never
      # fire idleness, freezing global progress, design §7/P4).
      def now_processing
        current = @epoch + (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at).to_i
        guard!(current)
        @last = current
        current
      end

      def now_event(watermark)
        watermark
      end

      def advance(delta)
        raise StreamClockError, "a wall clock cannot be advanced"
      end

      private

      def guard!(value)
        return if value >= @last

        raise StreamClockError, "stream clock regressed from #{@last} to #{value}"
      end
    end

    class ReplayClock
      include StreamClock

      def initialize(start: 0)
        @virtual = Integer(start)
        @last = @virtual
      end

      def now_processing
        guard!(@virtual)
        @virtual
      end

      def now_event(watermark)
        guard!(watermark)
        watermark
      end

      def advance(delta)
        raise StreamClockError, "delta must be non-negative" unless delta.is_a?(Integer) && delta >= 0

        @virtual += delta
        @virtual
      end

      private

      def guard!(value)
        return if value >= @last

        raise StreamClockError, "stream clock regressed from #{@last} to #{value}"
      end
    end
  end
end
