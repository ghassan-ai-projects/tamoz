# frozen_string_literal: true

module Tamoz
  module Observability
    # The seam every producer talks to (design §6.4). Contract only;
    # implementations ship with the journal slice.
    module Recorder
      # Record one signal. MUST NOT raise. MUST NOT block beyond the declared
      # hand-off bound. Returns :recorded | :dropped.
      def record(signal) = raise NotImplementedError

      # Bounded snapshot: per-lane depth, drops by reason, export state, policy digest.
      def health = raise NotImplementedError

      # Flush within a deadline; returns what remains unflushed.
      def flush(deadline_ms:) = raise NotImplementedError
    end
  end
end
