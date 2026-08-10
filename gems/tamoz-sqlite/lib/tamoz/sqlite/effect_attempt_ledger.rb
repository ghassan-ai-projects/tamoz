# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Writes attempt rows and advances an effect head within an open transaction.
    module EffectAttemptLedger
      module_function

      # Attempt insertion and head advancement are the durable retry grant; keep
      # their named fields explicit so the fence and deadline remain auditable.
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      # :reek:LongParameterList -- these are the complete attempt-row fields.
      def insert!(
        transaction,
        effect_key:,
        attempt_number:,
        attempt_token:,
        fence:,
        attempt_ttl:,
        now:
      )
        deadline = now + (attempt_ttl * 1_000).ceil
        transaction.execute(
          'effect.attempt.insert',
          <<~SQL,
            INSERT INTO tamoz_effect_attempts(
              effect_key, attempt_number, attempt_token, fence, status,
              deadline_ms, result, result_digest, external_id, error,
              error_digest, prepared_at_ms, started_at_ms, completed_at_ms
            )
            VALUES (
              ?, ?, ?, ?, 'prepared', ?, NULL, NULL, NULL, NULL,
              NULL, ?, NULL, NULL
            )
          SQL
          [effect_key, attempt_number, attempt_token, fence, deadline, now]
        )
      end

      # :reek:LongParameterList -- the retry grant carries its full fence and
      # deadline authority through the open transaction.
      def grant_next!(transaction, row:, effect_key:, token:, fence:, attempt_ttl:, now:)
        attempt_number = row.fetch(10) + 1
        insert!(
          transaction,
          effect_key:,
          attempt_number:,
          attempt_token: token,
          fence:,
          attempt_ttl:,
          now:
        )
        transaction.execute(
          'effect.attempt.advance',
          <<~SQL,
            UPDATE tamoz_effects
            SET status = 'prepared', current_attempt = ?,
                updated_at_ms = ?
            WHERE effect_key = ?
          SQL
          [attempt_number, now, effect_key]
        )
        EffectTransitionLog.append!(
          transaction,
          effect_key:,
          transition: 'retry.prepare',
          attempt_number:,
          actor: nil,
          evidence: {},
          now:
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists
    end

    private_constant :EffectAttemptLedger
  end
end
