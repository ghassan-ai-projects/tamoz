# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # The transport adapter seam (design §6.4). A transport authenticates
    # against the remote surface, polls bounded batches, delivers exactly one
    # bounded API effect per Delivery, and signals ephemeral, unjournaled,
    # best-effort state (typing indicators, callback acks).
    #
    # Telegram has no acknowledge endpoint, so a poll's `next_offset` is
    # persisted only after the whole returned prefix has a durable disposition
    # and is supplied on the NEXT call — a crash before it redelivers; a crash
    # after it cannot lose work because the offset was already durable.
    #
    # This is a structural contract: `tamoz-telegram` implements it without a
    # runtime reference to this constant (dependency rule 9), and the
    # conformance suite drives all four methods against an in-memory fixture
    # that can duplicate/reorder updates, throttle, lose a poll response, and
    # time out mid-send.
    # :reek:UnusedParameters -- contract signatures; the bodies raise because
    # a seam has nothing to implement (dependency rule 9).
    module Transport
      # @param descriptor [SurfaceDescriptor] the deployed surface.
      # @param credential [Tamoz::Secret] the bot token.
      # @return [Identity] authenticated surface identity (Telegram: getMe).
      # @raise [AuthenticationError] wrong or revoked credential; the gateway
      #   records it and stops — this is not a retry condition.
      def authenticate(descriptor, credential)
        raise NotImplementedError
      end

      # @param next_offset [Integer, nil] candidate next offset, confirming the
      #   prior durable prefix remotely.
      # @param limit [Integer] bounded batch size.
      # @param timeout_s [Integer] long-poll seconds.
      # @return [PollBatch] bounded updates plus the candidate next_offset.
      def poll(next_offset:, limit:, timeout_s:)
        raise NotImplementedError
      end

      # @param delivery [Delivery] exactly one bounded API effect.
      # @return [Receipt] platform message id + platform time.
      # @raise [AmbiguousDeliveryError] the send may or may not have happened.
      # @raise [ThrottledError] carries the server's authoritative retry_after.
      def deliver(delivery)
        raise NotImplementedError
      end

      # @param kind [Symbol] ephemeral signal kind (e.g. :typing, :ack).
      # @param fields [Hash] signal fields.
      def signal(kind, **fields)
        raise NotImplementedError
      end
    end
  end
end
