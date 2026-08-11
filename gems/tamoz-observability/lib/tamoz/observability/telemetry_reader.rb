# frozen_string_literal: true

module Tamoz
  module Observability
    module TelemetryReader
      CONTRACT_VERSION = 1

      def checkpoint_records(thread:, namespace:, execution: nil) = raise NotImplementedError
      def turn_records(thread:, execution: nil) = raise NotImplementedError
      def effect_records(thread:, execution: nil) = raise NotImplementedError
      def decision_records(thread:, occurrence: nil) = raise NotImplementedError
      def store_records(namespace:, limit:) = raise NotImplementedError
      def census = raise NotImplementedError
    end
  end
end
