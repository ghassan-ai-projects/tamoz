# frozen_string_literal: true

module Tamoz
  module Graph
    RequestRecord = Data.define(
      :thread_id,
      :namespace,
      :request_id,
      :enqueue_sequence,
      :input_digest,
      :operation,
      :delivery_mode,
      :status,
      :payload,
      :execution_id,
      :target_execution_id,
      :cancellation_generation,
      :checkpoint_id,
      :response,
      :terminal_error,
      :retryable,
      :created_at_ms,
      :updated_at_ms
    ) do
      TERMINAL_STATUSES = %i[completed failed].freeze

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end
    end
  end
end
