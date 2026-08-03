# frozen_string_literal: true

module Tamoz
  module Stream
    # P14-D (plan §3, C4) — the production ChannelConnector/SourceSession
    # contract. This seam is what makes a real-adapter swap safe: the
    # simulated fixture implements EXACTLY this contract, so swapping in a real
    # broker/device adapter cannot silently weaken the proven guarantees.
    #
    # Zone rule (design §4): the connector zone receives the source credential
    # and raw payload ONLY — never model/tool credentials or effector
    # authority.
    module ChannelConnector
      # @param source_identity [String] the declared source identity.
      # @param credential [Object] the credential to validate.
      # @return [SourceSession] an authenticated read session.
      # @raise [AuthenticationError] for wrong key / forged identity / replayed
      #   credential — the caller records a durable rejection (never a silent
      #   drop, never admission).
      def authenticate(source_identity, credential)
        raise NotImplementedError
      end
    end

    # A wrong-key, forged-identity, or replayed-credential failure. Typed so
    # the store can write a durable rejection record with the reason class.
    class AuthenticationError < StreamError
      CATEGORY = "stream_authentication"

      attr_reader :reason

      def initialize(reason, message = nil)
        @reason = reason
        super(message || reason)
      end
    end

    # A bounded, typed read session over one authenticated source.
    module SourceSession
      # @return [EventEnvelope, nil] the next event, or nil when the source is
      #   idle. Bounded and typed; never a raw instruction.
      def read
        raise NotImplementedError
      end

      # Acknowledge ONLY after the event and its admission metadata are
      # durably appended (design §6: at-least-once plus application dedup).
      def ack(event_id)
        raise NotImplementedError
      end
    end
  end
end
