# frozen_string_literal: true

module Tamoz
  module Observability
    class Notifier
      def initialize(recorder:, policy: ContentPolicy::NONE)
        @producer = Producer.new(recorder:, policy:)
      end

      def instrument(name, payload = {}, &block)
        return handle_unregistered(&block) unless Catalog.registered?(name)

        correlation, attributes = decompose(payload)
        dispatch(name, correlation, attributes, &block)
      rescue StandardError
        raise if block_given?

        false
      end

      private

      def handle_unregistered(&block)
        return yield if block_given?

        false
      end

      def decompose(payload)
        payload = payload.to_h
        correlation = payload[:correlation] || payload['correlation'] || {}
        attributes = payload.reject { |key, _| key.to_sym == :correlation }
        [correlation, attributes]
      end

      def dispatch(name, correlation, attributes, &block)
        if block_given?
          @producer.around(name, correlation:, attributes:) { yield }
        else
          @producer.emit(name, correlation:, attributes:)
        end
      end
    end
  end
end
