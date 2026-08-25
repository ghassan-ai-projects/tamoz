# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Records terminal, idempotent, and late effect receipts.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy -- the receipt comparisons and
    # ordered CAS updates are the durable contract owned by this effect boundary.
    # :reek:TooManyStatements :reek:LongParameterList -- the receipt fields and
    # ordered SQL branches are one atomic durable contract.
    # :reek:RepeatedConditional -- each changes check guards a different CAS.
    class EffectCompletion
      def initialize(store:, record_reader:, terminal_attempt_statuses:)
        @store = store
        @record_reader = record_reader
        @terminal_attempt_statuses = terminal_attempt_statuses
        freeze
      end

      # The terminal receipt and head update share one transaction so replay and
      # late receipts retain their exact historical ordering.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:disable Metrics/ParameterLists, Metrics/BlockLength
      def complete(
        key:,
        attempt_token:,
        status:,
        result: nil,
        external_id: nil,
        error: nil
      )
        effect_key = Wire.identity(key, name: 'effect key')
        token = Wire.identity(attempt_token, name: 'effect attempt token')
        status_text = EffectJournalValidation.enum_text!(
          status,
          %w[succeeded failed unknown],
          'effect completion status'
        )
        external = external_id &&
                   Wire.identity(external_id, name: 'effect external id')
        result_bytes = @store.checkpoint_codec.state_codec.dump(result)
        error_bytes = @store.checkpoint_codec.state_codec.dump(error)
        result_digest = Wire.digest(
          result_bytes,
          domain: 'tamoz.sqlite.effect_result'
        )
        error_digest = Wire.digest(
          error_bytes,
          domain: 'tamoz.sqlite.effect_error'
        )

        @store.adapter.__send__(:transaction, operation: 'effect.complete') do |tx|
          now = @store.adapter.__send__(:backend_time, tx, 'effect.complete.time')
          row = tx.first(
            'effect.complete.row',
            <<~SQL,
              SELECT a.attempt_number, a.status, a.result, a.result_digest,
                     a.external_id, a.error, a.error_digest,
                     e.current_attempt, e.status
              FROM tamoz_effect_attempts a
              JOIN tamoz_effects e ON e.effect_key = a.effect_key
              WHERE a.effect_key = ? AND a.attempt_token = ?
            SQL
            [effect_key, token]
          )
          raise CheckpointConflictError, 'effect attempt token does not exist' unless row

          attempt_number = row.fetch(0)
          attempt_status = row.fetch(1)
          stored_result_bytes = row.fetch(2)
          stored_result_digest = row.fetch(3)
          stored_external_id = row.fetch(4)
          stored_error_bytes = row.fetch(5)
          stored_error_digest = row.fetch(6)
          head_current_attempt = row.fetch(7)
          head_status = row.fetch(8)

          if @terminal_attempt_statuses.include?(attempt_status)
            unless attempt_status == status_text &&
                   stored_result_bytes == result_bytes &&
                   stored_result_digest == result_digest &&
                   stored_external_id == external &&
                   stored_error_bytes == error_bytes &&
                   stored_error_digest == error_digest
              raise CheckpointConflictError,
                    'effect attempt already has a different terminal receipt'
            end
            next
          end
          unless %w[running unknown].include?(attempt_status)
            raise CheckpointConflictError,
                  'effect completion requires a started attempt'
          end

          tx.execute(
            'effect.complete.attempt',
            <<~SQL,
              UPDATE tamoz_effect_attempts
              SET status = ?, result = ?, result_digest = ?,
                  external_id = ?, error = ?, error_digest = ?,
                  completed_at_ms = ?
              WHERE effect_key = ? AND attempt_number = ?
                AND attempt_token = ? AND status IN ('running', 'unknown')
            SQL
            [
              status_text, Wire.blob(result_bytes), result_digest, external,
              Wire.blob(error_bytes), error_digest, now, effect_key,
              attempt_number, token
            ]
          )
          raise CheckpointConflictError, 'effect receipt commit lost' unless tx.changes == 1

          if attempt_number == head_current_attempt
            if head_status == 'succeeded'
              tx.execute(
                'effect.complete.succeeded_head',
                <<~SQL,
                  UPDATE tamoz_effects
                  SET requires_reconciliation = CASE
                        WHEN ? = 'succeeded' THEN requires_reconciliation
                        ELSE 1
                      END,
                      updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                    AND status = 'succeeded'
                SQL
                [status_text, now, effect_key, attempt_number]
              )
            elsif %w[failed abandoned].include?(head_status) &&
                  status_text == 'succeeded'
              tx.execute(
                'effect.complete.resolved_conflict',
                <<~SQL,
                  UPDATE tamoz_effects
                  SET status = 'reconcile', requires_reconciliation = 1,
                      updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                SQL
                [now, effect_key, attempt_number]
              )
            else
              tx.execute(
                'effect.complete.head',
                <<~SQL,
                  UPDATE tamoz_effects
                  SET status = ?, updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                SQL
                [status_text, now, effect_key, attempt_number]
              )
            end
          elsif status_text == 'succeeded'
            tx.execute(
              'effect.complete.late',
              <<~SQL,
                UPDATE tamoz_effects
                SET status = CASE
                      WHEN status = 'succeeded' THEN 'succeeded'
                      ELSE 'reconcile'
                    END,
                    requires_reconciliation = 1,
                    updated_at_ms = ?
                WHERE effect_key = ?
              SQL
              [now, effect_key]
            )
          end
          EffectTransitionLog.append!(
            tx,
            effect_key:,
            transition: "complete.#{status_text}",
            attempt_number:,
            actor: nil,
            evidence: { 'late' => attempt_number != head_current_attempt },
            now:
          )
        end
        @record_reader.fetch(effect_key)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:enable Metrics/ParameterLists, Metrics/BlockLength
    end

    private_constant :EffectCompletion
  end
end
