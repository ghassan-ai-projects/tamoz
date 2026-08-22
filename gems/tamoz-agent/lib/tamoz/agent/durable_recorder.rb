# frozen_string_literal: true

module Tamoz
  module Agent
    # Option A: force the async journal through a flush boundary before returning.
    class DurableRecorder
      FLUSH_DEADLINE_MS = 1_000

      def initialize(recorder:)
        @recorder = recorder
      end

      def record(signal)
        result = @recorder.record(signal)
        @recorder.flush(deadline_ms: FLUSH_DEADLINE_MS) if result == :recorded
        result
      end

      def health = @recorder.health

      def flush(deadline_ms:)
        @recorder.flush(deadline_ms:)
      end

      def close
        @recorder.flush(deadline_ms: FLUSH_DEADLINE_MS)
      ensure
        @recorder.close if @recorder.respond_to?(:close)
      end
    end

    private_constant :DurableRecorder
  end
end
