# frozen_string_literal: true

module Tamoz
  module Observability
    class Notifier
      def initialize(recorder:, policy: ContentPolicy::NONE)
        @producer = Producer.new(recorder:, policy:)
      end

      def instrument(name, payload = {})
        return yield if !Catalog.registered?(name) && block_given?
        return false unless Catalog.registered?(name)

        payload = payload.to_h
        correlation = payload[:correlation] || payload['correlation'] || {}
        attributes = payload.reject { |key, _| key.to_sym == :correlation }
        if block_given?
          @producer.around(name, correlation:, attributes:) { yield }
        else
          @producer.emit(name, correlation:, attributes:)
        end
      rescue StandardError
        raise if block_given?

        false
      end
    end
  end
end
