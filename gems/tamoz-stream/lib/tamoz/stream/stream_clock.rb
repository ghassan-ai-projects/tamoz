# frozen_string_literal: true

module Tamoz
  module Stream
    # P14-B (design §5, plan §5/C1) — the injected StreamClock. The stream
    # tables NEVER call `backend_time`/wall time: every timestamp written
    # inside `process_partition` comes from this clock, so replay re-executes
    # the identical operator chain under the same virtual clock and produces
    # byte-identical state. `now_processing` is the runtime's processing time;
    # `now_event(watermark)` answers "what is the current event time given the
    # partition watermark"; `advance(delta)` is the replay-mode stepper.
    #
    # A monotonicity violation raises `StreamClockError`. Neither the
    # processing clock nor the event clock may regress; the two are guarded as
    # separate sequences by `guard_monotonic!` below, so both implementations
    # enforce the identical rule (partition-level watermark regression is a
    # different concern, guarded by `WatermarkRegressionError`).
    module StreamClock
      def now_processing
        raise NotImplementedError
      end

      def now_event(watermark)
        raise NotImplementedError
      end

      def advance(delta)
        raise NotImplementedError
      end

      private

      # The monotonicity rule both implementations share, in ONE place: a value
      # may repeat but never regress, and observing a value advances the mark
      # (a guard that never records its own high-water mark is dead code).
      #
      # Processing time and event time are separate sequences on separate
      # scales, so each carries its own mark — an event watermark must never be
      # able to trip the processing guard, or vice versa.
      def guard_monotonic!(sequence, value)
        marks = (@monotonic_marks ||= {})
        last = marks[sequence]
        raise StreamClockError, "stream #{sequence} clock regressed from #{last} to #{value}" if last && value < last

        marks[sequence] = value
      end
    end
  end
end
