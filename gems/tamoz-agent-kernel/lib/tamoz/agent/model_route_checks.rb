# frozen_string_literal: true

require 'tamoz/agent/errors'

module Tamoz
  module Agent
    # The refusals a model client build makes before it reaches the network.
    module ModelRouteChecks
      private

      def ensure_model!(model, provider)
        return if model.is_a?(String) && !model.empty? &&
                  (provider != 'openrouter' || model.include?('/'))

        code = model.is_a?(String) && !model.empty? ? 'model_invalid' : 'model_required'
        raise ModelCallError.new(code:)
      end

      def ensure_role_binding!(role, provider, model)
        return unless role
        return if role.provider.to_s == provider && role.model.to_s == model

        raise ModelCallError.new(code: 'profile_role_mismatch')
      end

      def ensure_protocol!(descriptor, _provider)
        return unless descriptor.fetch(:kind) == 'rejected'

        raise ModelCallError.new(code: 'native_protocol_rejected')
      end

      def ensure_endpoint!(endpoint, _provider)
        return if endpoint.is_a?(String) && !endpoint.empty?

        raise ModelCallError.new(code: 'endpoint_unavailable')
      end

      def normalize_safety(safety)
        value = safety.to_sym if safety.respond_to?(:to_sym)
        return value if %i[unsafe idempotent].include?(value)

        raise ModelCallError.new(code: 'safety_invalid')
      end
    end
  end
end
