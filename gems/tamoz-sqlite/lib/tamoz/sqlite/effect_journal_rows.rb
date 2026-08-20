# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Keeps the durable effect and current-attempt row shapes canonical.
    module EffectJournalRows
      module_function

      def effect(transaction, effect_key, label)
        transaction.first(
          label,
          <<~SQL,
            SELECT effect_key, logical_key, thread_id, namespace, execution_id, task_id,
                   call_index, operation, safety, status, request_digest,
                   current_attempt, requires_reconciliation,
                   created_at_ms, updated_at_ms
            FROM tamoz_effects
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
      end

      # :reek:LongParameterList -- transaction, key, attempt number, and the
      # operation label together identify one durable row query.
      def attempt(transaction, effect_key, attempt_number, label)
        transaction.first(
          label,
          <<~SQL,
            SELECT attempt_number, attempt_token, fence, status, deadline_ms
            FROM tamoz_effect_attempts
            WHERE effect_key = ? AND attempt_number = ?
          SQL
          [effect_key, attempt_number]
        )
      end
    end

    private_constant :EffectJournalRows
  end
end
