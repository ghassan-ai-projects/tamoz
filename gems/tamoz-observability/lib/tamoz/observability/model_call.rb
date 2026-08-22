# frozen_string_literal: true

module Tamoz
  module Observability
    # Emits the catalogued model-call signal for live and durable calls.
    class ModelCall
      def initialize(producer:, provider:, model:)
        @producer = producer
        @provider = String(provider)
        @model = String(model)
      end

      def call(correlation:, usage: nil, cost: nil, content: nil, &)
        attributes = attributes_for(usage:, cost:)
        @producer.around(
          'tamoz.model.call', correlation:, attributes:, content:, &
        )
      end

      def emit(correlation:, started_at_ms:, ended_at_ms:, usage: nil, request_digest: nil)
        attributes = attributes_for(usage:, cost: nil)
        attributes[:duration_ms] = ended_at_ms - started_at_ms
        attributes[:request_digest] = request_digest if request_digest
        @producer.emit(
          'tamoz.model.call', correlation:, attributes:, timing: :interval,
                              started_at_ms:, ended_at_ms:
        )
      end

      private

      def attributes_for(usage:, cost:)
        attributes = { provider: @provider, model: @model }
        attributes.merge!(usage.to_h.transform_keys(&:to_sym)) if usage.is_a?(Usage)
        attributes.merge!(cost_attributes(cost)) if cost.is_a?(Cost)
        attributes
      end

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
