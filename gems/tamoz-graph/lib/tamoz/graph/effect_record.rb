# frozen_string_literal: true

module Tamoz
  module Graph
    EffectAttempt = Data.define(
      :identity,
      :attempt_number,
      :attempt_token,
      :fence,
      :status,
      :deadline_ms,
      :result,
      :external_id,
      :error,
      :prepared_at_ms,
      :started_at_ms,
      :completed_at_ms
    )

    EffectRecord = Data.define(
      :key,
      :logical_key,
      :thread_id,
      :namespace,
      :execution_id,
      :task_id,
      :call_index,
      :operation,
      :safety,
      :status,
      :request_digest,
      :current_attempt,
      :requires_reconciliation,
      :attempts,
      :created_at_ms,
      :updated_at_ms
    )

    EffectDecision = Data.define(:action, :record, :attempt_token)
  end
end
