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
    # A monotonicity violation raises `StreamClockError` (the processing clock
    # must never regress; event-time watermarks are guarded separately by
    # `WatermarkRegressionError`).
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
    end
  end
end
