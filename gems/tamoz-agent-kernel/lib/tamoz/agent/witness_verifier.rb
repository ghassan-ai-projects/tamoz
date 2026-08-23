# frozen_string_literal: true

require "json"
require "digest"
require "openssl"
require "tamoz/core"
require "tamoz/agent/errors"
require "tamoz/agent/witness_gateway"

module Tamoz
  module Agent
    # P3 (provenance/replay): the independent witness VERIFIER. It checks that
    # a receipt's claimed digests and identity match the witness gateway's
    # SIGNED record — Tamoz's own events are not evidence; the gateway's
    # signature is (B8).
    #
    # The signature is recomputed over the RECORD's own canonical payload
    # (Record#to_payload) — the verifier never trusts a caller-supplied
    # payload, so a forged record cannot ride a signature that was computed
    # over different bytes.
    #
    # A dummy-request attack (altered frame bytes, an ignored response, a
    # forged receipt) breaks the binding: the receipt digests cannot match a
    # signed record that was computed over different bytes.
    class WitnessVerifier
      def self.verify(receipt:, gateway_record:, signing_key:)
        new(signing_key:).verify(receipt:, gateway_record:)
      end

      def initialize(signing_key:)
        @signing_key = String(signing_key)
      end

      # Returns the verified gateway record or raises a typed error.
      def verify(receipt:, gateway_record:)
        payload = gateway_record.to_payload
        expected = OpenSSL::HMAC.hexdigest("sha256", @signing_key, JSON.generate(payload))
        unless expected == gateway_record.signature
          raise ProtocolError, "witness_gateway/signature_invalid"
        end

        request_digest = field(receipt, :request_digest)
        response_digest = field(receipt, :response_digest)
        frame_digest = field(receipt, :frame_digest)
        settings_digest = field(receipt, :settings_digest)
        logical_call_id = if receipt.is_a?(Hash)
                            receipt.fetch("effect_id")
                          elsif receipt.respond_to?(:logical_call_key)
                            receipt.logical_call_key.to_key
                          else
                            raise ProtocolError, "witness_gateway/receipt_unreadable"
                          end
        provider = field(receipt, :provider)
        model = field(receipt, :model)

        if request_digest != gateway_record.request_digest
          raise ProtocolError, "witness_gateway/request_digest_mismatch"
        end
        if response_digest != gateway_record.response_digest
          raise ProtocolError, "witness_gateway/response_digest_mismatch"
        end
        if frame_digest != gateway_record.frame_digest
          raise ProtocolError, "witness_gateway/frame_digest_mismatch"
        end
        if settings_digest != gateway_record.settings_digest
          raise ProtocolError, "witness_gateway/settings_digest_mismatch"
        end
        if logical_call_id != gateway_record.logical_call_id
          raise ProtocolError, "witness_gateway/logical_call_id_mismatch"
        end
        if provider != gateway_record.provider || model != gateway_record.model
          raise ProtocolError, "witness_gateway/identity_mismatch"
        end

        gateway_record
      end

      private

      def field(receipt, name)
        if receipt.is_a?(Hash)
          receipt.fetch(name.to_s)
        else
          receipt.public_send(name)
        end
      end
    end
  end
end
