# frozen_string_literal: true

require 'securerandom'

require_relative 'canonical'

module Tamoz
  module Comms
    # One hashed pairing challenge (design §5/§7). The gateway stores only the
    # challenge digest; the plaintext challenge travels to the sender exactly
    # once, and the store's pairing row transitions pending → consumed on the
    # matching admission. The digest binds surface, correspondent and
    # conversation, so a challenge copied into another chat never pairs.
    # One hashed challenge value; the fields ARE the binding and the
    # validation is the per-field rule set.
    # :reek:LongParameterList, :reek:TooManyInstanceVariables, :reek:MissingSafeMethod
    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- the value contract.
    class PairingChallenge
      DIGEST_DOMAIN = 'tamoz.comms.pairing.v1'
      MAX_TEXT_BYTES = 256

      attr_reader :challenge, :digest, :surface_id, :correspondent_id,
                  :conversation_id, :expires_at

      def initialize(challenge:, digest:, surface_id:, correspondent_id:, conversation_id:, expires_at:)
        validate!(challenge:, digest:, surface_id:, correspondent_id:, conversation_id:, expires_at:)
        @challenge = challenge
        @digest = digest
        @surface_id = surface_id
        @correspondent_id = correspondent_id
        @conversation_id = conversation_id
        @expires_at = expires_at
        freeze
      end

      # Issues a fresh challenge for one correspondent; only its digest is
      # ever stored. `secret` is the per-surface pairing secret.
      def self.build(surface_id:, correspondent_id:, conversation_id:, ttl_s:, now:)
        challenge = SecureRandom.hex(16)
        digest = Canonical.hexdigest(
          DIGEST_DOMAIN,
          [surface_id, correspondent_id, conversation_id, challenge]
        )
        new(challenge:, digest:, surface_id:, correspondent_id:, conversation_id:,
            expires_at: now + ttl_s)
      end

      # Verifies a sender's presented challenge against the stored digest and
      # its bindings.
      def self.verify?(challenge:, digest:, surface_id:, correspondent_id:, conversation_id:)
        Canonical.hexdigest(
          DIGEST_DOMAIN,
          [surface_id, correspondent_id, conversation_id, challenge]
        ) == digest
      end

      private

      def validate!(challenge:, digest:, surface_id:, correspondent_id:, conversation_id:, expires_at:)
        unless challenge.is_a?(String) && !challenge.empty? && challenge.bytesize <= MAX_TEXT_BYTES
          raise ValidationError, 'challenge must be a bounded string'
        end
        unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          raise ValidationError, 'digest must be a 64-char hex digest'
        end

        [surface_id, correspondent_id, conversation_id].each do |value|
          unless value.is_a?(String) && !value.empty?
            raise ValidationError, 'pairing identity fields must be bounded strings'
          end
        end
        raise ValidationError, 'expires_at must be a Time value' unless expires_at.is_a?(Time)
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
