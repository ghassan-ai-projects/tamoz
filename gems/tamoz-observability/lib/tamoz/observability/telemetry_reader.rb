# frozen_string_literal: true

module Tamoz
  module Observability
    # The read-only contract a durable store implements so its record can be reconstructed and diagnosed.
    module TelemetryReader
      CONTRACT_VERSION = 2
      KINDS = %i[requests effects effect_attempts checkpoints approval_decisions occurrences].freeze

      def requests(thread: nil, limit: nil) = raise NotImplementedError
      def effects(thread: nil, limit: nil) = raise NotImplementedError
      def effect_attempts(thread: nil, limit: nil) = raise NotImplementedError
      def checkpoints(thread: nil, limit: nil) = raise NotImplementedError
      def approval_decisions(thread: nil, limit: nil) = raise NotImplementedError
      def occurrences(thread: nil, limit: nil) = raise NotImplementedError
      def close = raise NotImplementedError
    end
  end
end
