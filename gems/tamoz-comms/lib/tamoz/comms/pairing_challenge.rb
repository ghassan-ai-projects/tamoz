# frozen_string_literal: true

require 'securerandom'
require 'time'

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    PairingChallenge = Data.define(:challenge, :digest, :surface_id, :correspondent_id, :conversation_id,
                                   :expires_at)

    # One hashed pairing challenge (design §5/§7). The gateway stores only the
    # challenge digest; the plaintext challenge travels to the sender exactly
    # once, and the store's pairing row transitions pending → consumed on the
    # matching admission. The digest binds surface, correspondent and
    # conversation, so a challenge copied into another chat never pairs.
    # :reek:MissingSafeMethod
    class PairingChallenge
      DIGEST_DOMAIN = 'tamoz.comms.pairing.v1'
      MAX_TEXT_BYTES = 256
      CODE_LENGTH = 8
      CODE_ALPHABET = [*'A'..'Z', *'0'..'9'].freeze

      def initialize(**)
        super
        validate!
      end

      # A human-relayable code: uppercase alphanumeric, readable over a
      # voice or operator channel.
      def self.generate_code
        Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
      end

      # Issues a fresh challenge for one correspondent's chat (`binding`: surface_id, correspondent_id,
      # conversation_id); only its digest is ever stored. `code` supplies the relayable challenge
      # value; without one the challenge is an opaque hex string.
      def self.build(ttl_s:, now:, code: nil, **binding)
        challenge = code || SecureRandom.hex(16)
        new(challenge:, digest: digest_for(challenge:, **binding), expires_at: now + ttl_s, **binding)
      end

      # Verifies a sender's presented challenge against the stored digest and its bindings.
      def self.verify?(digest:, **presented) = digest_for(**presented) == digest

      def self.digest_for(challenge:, surface_id:, correspondent_id:, conversation_id:)
        Canonical.hexdigest(DIGEST_DOMAIN, [surface_id, correspondent_id, conversation_id, challenge])
      end

      # The durable row: everything but the plaintext challenge.
      def wire
        { 'challenge_digest' => digest, 'surface_id' => surface_id, 'correspondent_id' => correspondent_id,
          'conversation_id' => conversation_id, 'expires_at' => expires_at.getutc.iso8601(6) }
      end

      private

      def validate!
        Shapes.require_string!(challenge, 'challenge', max_bytes: MAX_TEXT_BYTES)
        raise ValidationError, 'digest must be a 64-char hex digest' unless Shapes.hex?(digest)
        unless [surface_id, correspondent_id, conversation_id].all? { |value| value.is_a?(String) && !value.empty? }
          raise ValidationError, 'pairing identity fields must be bounded strings'
        end

        Shapes.require_time!(expires_at, 'expires_at')
      end
    end
  end
end
