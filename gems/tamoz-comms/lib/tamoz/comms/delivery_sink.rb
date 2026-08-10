# frozen_string_literal: true

module Tamoz
  module Comms
    # The worker's ONLY channel seam (ADR-041, ADR-042): nil-safe, so an
    # unconfigured worker delivers nothing and never raises. The worker pushes
    # lifecycle events here; the integration (slice E) projects them onto the
    # delivery outbox. The worker never makes a channel network call.
    # :reek:UnusedParameters -- contract signature; the body raises because a
    # seam has nothing to implement.
    module DeliverySink
      # @param event [Hash] one normalized outbound event:
      #   `{thread_id:, occurrence_id:, kind:, text:, ...}` where kind is a
      #   lifecycle kind (:accepted, :answer, :failed, :stopped, :blocked,
      #   :approval_request).
      # @return [Symbol, nil] :accepted when the event was durably projected,
      #   nil when the sink is a null sink (nothing was sent).
      def push(event)
        raise NotImplementedError
      end

      # The default: nothing is delivered, nothing raises, nothing is recorded.
      # A worker started without a comms surface is indistinguishable from one
      # whose surface is `:disabled`.
      # @return [DeliverySink]
      def self.null
        @null ||= NullSink.new
      end

      # A sink that accepts and discards every event.
      class NullSink
        def push(_event) = nil
      end
    end
  end
end
