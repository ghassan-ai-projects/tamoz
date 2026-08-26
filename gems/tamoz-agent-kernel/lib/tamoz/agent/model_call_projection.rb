# frozen_string_literal: true

require "tamoz/agent/errors"
require "tamoz/core"

module Tamoz
  module Agent
    module ModelCallProjection
      KEYS = %w[
        request_digest content response_digest usage settings_digest
        provider_configuration_digest
      ].freeze
      RESPONSE_FIELDS = %i[
        content request_digest response_digest usage settings_digest
        provider_configuration_digest
      ].freeze

      module_function

      def from_response(response, request_digest: nil, settings_digest: nil,
                        provider_configuration_digest: nil)
        verify_response_shape!(response)
        request_digest ||= response.request_digest
        verify_binding!("request_digest", response.request_digest, request_digest)
        verify_binding!("settings_digest", response.settings_digest, settings_digest)
        verify_binding!(
          "provider_configuration_digest", response.provider_configuration_digest,
          provider_configuration_digest
        )

        projection = {
          "request_digest" => request_digest,
          "content" => response.content,
          "response_digest" => response.response_digest,
          "usage" => usage_projection(response.usage),
          "settings_digest" => response.settings_digest,
          "provider_configuration_digest" => response.provider_configuration_digest
        }
        validate!(projection)
      rescue ModelReceiptError => error
        raise ModelCallError.new(code: "invalid_projection", body_bytes: error.message.bytesize)
      end

      def validate!(projection, request_digest: nil, settings_digest: nil,
                    provider_configuration_digest: nil)
        unless projection.is_a?(Hash) && projection.keys.sort == KEYS.sort
          raise ModelReceiptError, "model_projection/shape"
        end
        ModelCall.require_digest!("model_projection.request_digest", projection["request_digest"])
        ModelCall.require_digest!("model_projection.response_digest", projection["response_digest"])
        ModelCall.require_digest!("model_projection.settings_digest", projection["settings_digest"])
        ModelCall.require_digest!(
          "model_projection.provider_configuration_digest",
          projection["provider_configuration_digest"]
        )
        verify_binding!("request_digest", projection["request_digest"], request_digest)
        verify_binding!("settings_digest", projection["settings_digest"], settings_digest)
        verify_binding!(
          "provider_configuration_digest", projection["provider_configuration_digest"],
          provider_configuration_digest
        )
        raise ModelReceiptError, "model_projection/content" unless projection["content"].is_a?(String)
        validate_usage!(projection["usage"])
        Tamoz::Core.deep_freeze(projection)
      end

      def usage_projection(usage)
        return nil if usage.nil?
        unless usage.respond_to?(:available)
          raise ModelReceiptError, "model_projection/usage"
        end
        return nil unless usage.available

        {
          "input_tokens" => usage.input_tokens,
          "output_tokens" => usage.output_tokens,
          "cost_microunits" => usage.cost_microunits
        }
      end

      def verify_binding!(name, actual, expected)
        return if expected.nil? || actual == expected

        raise ModelReceiptError, "model_projection/#{name}_mismatch"
      end
      private_class_method :verify_binding!

      def verify_response_shape!(response)
        return if RESPONSE_FIELDS.all? { |field| response.respond_to?(field) }

        raise ModelCallError.new(code: "invalid_projection")
      end
      private_class_method :verify_response_shape!

      def validate_usage!(usage)
        return if usage.nil?
        unless usage.is_a?(Hash) && %w[input_tokens output_tokens cost_microunits].all? { |key| usage.key?(key) }
          raise ModelReceiptError, "model_projection/usage"
        end
        return if usage.values.all? { |value| value.is_a?(Integer) && value >= 0 }

        raise ModelReceiptError, "model_projection/usage"
      end
      private_class_method :validate_usage!
    end
  end
end
