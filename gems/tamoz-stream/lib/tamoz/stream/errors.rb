# frozen_string_literal: true

module Tamoz
  module Stream
    # Base error for the stream package. Typed failures (invariant 17):
    # admission rejections/quarantines are DURABLE OUTCOMES, never raised; the
    # raised classes are the operational failures below.
    class StreamError < StandardError
      CATEGORY = "stream"
      RETRYABLE = false
    end

    # The interlock reader failed or is unavailable. FAIL CLOSED: no dispatch
    # (design §10, plan §10).
    class InterlockUnavailableError < StreamError
      CATEGORY = "stream_interlock_unavailable"
    end

    # A partition's watermark moved backward (design §7: monotonic per
    # partition). The partition halts; typed; operator-visible.
    class WatermarkRegressionError < StreamError
      CATEGORY = "stream_watermark_regression"
    end

    # The quarantine log is full. Bounded; a gap record is written; never a
    # silent drop (design §6).
    class QuarantineOverflowError < StreamError
      CATEGORY = "stream_quarantine_overflow"
    end

    # The derived bridge request id is oversized. Raised at BUILD time, never
    # at enqueue (plan §6, Wire::MAX_REQUEST_ID_BYTES).
    class RequestIdTooLongError < StreamError
      CATEGORY = "stream_request_id_too_long"
    end

    # The injected clock moved backward or produced an inconsistent read.
    class StreamClockError < StreamError
      CATEGORY = "stream_clock"
    end
  end
end
