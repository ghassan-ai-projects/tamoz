# frozen_string_literal: true

module Tamoz
  module Comms
    # Base error for the communications package. Typed failures only: the
    # gateway, the worker seam and the CLI each map transport/storage failures
    # onto the subclass that tells the caller what to do next.
    class CommsError < StandardError
    end

    # A value failed its declared shape — a bounded id, a direction, a digest.
    # Raised at construction, so an invalid record can never enter a store.
    class ValidationError < CommsError
    end

    # The transport credential was refused by the remote surface (getMe).
    # The gateway records it and stops; it is not a retry condition.
    class AuthenticationError < CommsError
    end

    # A send may or may not have happened. The caller must not guess and must
    # not retry (design §10).
    class AmbiguousDeliveryError < CommsError
    end

    # The remote surface rate-limited the caller; `retry_after` carries the
    # authoritative server delay.
    class ThrottledError < CommsError
    end

    # A second poller or a configured webhook competes for the same bot token.
    # Fatal and named: two pollers are a correctness problem, not a retry.
    class PollerConflictError < CommsError
    end
  end
end
