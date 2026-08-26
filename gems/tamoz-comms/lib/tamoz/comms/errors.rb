# frozen_string_literal: true

module Tamoz
  module Comms
    # Base error for the communications package. Typed failures only: the
    # gateway, the worker seam and the CLI each map transport/storage failures
    # onto the subclass that tells the caller what to do next.
    class CommsError < Tamoz::Error
      CATEGORY = "comms"
      SAFE_MESSAGE = "A communications operation failed."
    end

    # A value failed its declared shape — a bounded id, a direction, a digest.
    # Raised at construction, so an invalid record can never enter a store.
    class ValidationError < CommsError
      CATEGORY = "comms_validation"
      SAFE_MESSAGE = "The communications record is invalid."
    end

    # The transport credential was refused by the remote surface (getMe).
    # The gateway records it and stops; it is not a retry condition.
    class AuthenticationError < CommsError
      CATEGORY = "comms_authentication"
      SAFE_MESSAGE = "The communications credential was refused."
    end

    # A send may or may not have happened. The caller must not guess and must
    # not retry (design §10).
    class AmbiguousDeliveryError < CommsError
      CATEGORY = "comms_ambiguous_delivery"
      SAFE_MESSAGE = "The delivery outcome is ambiguous."
    end

    # The transport response exceeded its configured byte cap before a
    # complete result was observed. The adapter maps this to the operation's
    # outcome semantics: poll is transient, send is ambiguous.
    class ResponseTooLargeError < CommsError
      CATEGORY = "comms_response_too_large"
      SAFE_MESSAGE = "The communications response exceeded its configured limit."
    end

    # An IDEMPOTENT read did not complete — a long poll that timed out, a
    # dropped connection. Nothing was observed and nothing was persisted, so
    # the caller retries from unchanged durable state. This is the normal
    # weather of long polling, and it is precisely NOT AmbiguousDeliveryError:
    # that one says an effect may already have happened.
    class TransientTransportError < CommsError
      CATEGORY = "comms_transient_transport"
      RETRYABLE = true
      SAFE_MESSAGE = "The communications transport failed transiently."
    end

    # The remote surface rate-limited the caller; `retry_after` carries the
    # authoritative server delay.
    class ThrottledError < CommsError
      CATEGORY = "comms_throttled"
      RETRYABLE = true
      SAFE_MESSAGE = "The communications surface is rate-limited."

      attr_reader :retry_after

      def initialize(message, retry_after: 1)
        super(message)
        @retry_after = retry_after
      end
    end

    # A second poller or a configured webhook competes for the same bot token.
    # Fatal and named: two pollers are a correctness problem, not a retry.
    class PollerConflictError < CommsError
      CATEGORY = "comms_poller_conflict"
      SAFE_MESSAGE = "A competing poller holds the communications surface."
    end
  end
end
