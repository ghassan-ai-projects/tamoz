# frozen_string_literal: true

module Tamoz
  module Observability
    class ModelCall
      def initialize(producer:, provider:, model:)
        @producer = producer
        @provider = String(provider)
        @model = String(model)
      end

      def call(correlation:, usage: nil, cost: nil, content: nil)
        attributes = {provider: @provider, model: @model}
        attributes.merge!(usage.to_h.transform_keys(&:to_sym)) if usage.is_a?(Usage)
        attributes.merge!(cost_attributes(cost)) if cost.is_a?(Cost)
        @producer.around(
          'tamoz.model.call', correlation:, attributes:, content:
        ) { yield }
      end

      private

      def cost_attributes(cost)
        {
          cost_value: format('%.12g', cost.value),
          cost_currency: cost.currency,
          cost_basis: cost.basis,
          pricing_source: cost.pricing_source,
          pricing_version: cost.pricing_version
        }
      end
    end
  end
end
