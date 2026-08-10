# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Starts an effect only when its current lease fence authorizes execution.
    class EffectLifecycle
      def initialize(store:, guard:, record_reader:)
        @store = store
        @guard = guard
        @record_reader = record_reader
        freeze
      end

      # Keep lease validation, attempt CAS, head CAS, and audit append in one
      # visible transaction sequence.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
      # :reek:DuplicateMethodCall -- repeated row and transaction reads are the
      # ordered durable predicates for fencing.
      # :reek:TooManyStatements -- the start transaction is one ordered CAS.
      def start(key:, attempt_token:)
        effect_key = Wire.identity(key, name: 'effect key')
        token = Wire.identity(attempt_token, name: 'effect attempt token')
        lease = @guard.lease
        @store.adapter.__send__(:transaction, operation: 'effect.start') do |tx|
          now = @store.adapter.__send__(:backend_time, tx, 'effect.start.time')
          @store.adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'effect.start.lease'
          )
          row = tx.first(
            'effect.start.row',
            <<~SQL,
              SELECT e.current_attempt, e.status, a.fence, a.status,
                     a.deadline_ms
              FROM tamoz_effects e
              JOIN tamoz_effect_attempts a
                ON a.effect_key = e.effect_key
               AND a.attempt_number = e.current_attempt
              WHERE e.effect_key = ? AND a.attempt_token = ?
            SQL
            [effect_key, token]
          )
          unless row &&
                 row.fetch(1) == 'prepared' &&
                 row.fetch(2) == lease.fence &&
                 row.fetch(3) == 'prepared' &&
                 row.fetch(4) > now
            raise LeaseLostError,
                  'effect attempt is expired, stale, or no longer prepared'
          end
          tx.execute(
            'effect.start.attempt',
            <<~SQL,
              UPDATE tamoz_effect_attempts
              SET status = 'running', started_at_ms = ?
              WHERE effect_key = ? AND attempt_number = ?
                AND attempt_token = ? AND status = 'prepared'
            SQL
            [now, effect_key, row.fetch(0), token]
          )
          raise CheckpointConflictError, 'effect start lost' unless tx.changes == 1

          tx.execute(
            'effect.start.head',
            <<~SQL,
              UPDATE tamoz_effects
              SET status = 'running', updated_at_ms = ?
              WHERE effect_key = ? AND current_attempt = ?
                AND status = 'prepared'
            SQL
            [now, effect_key, row.fetch(0)]
          )
          raise CheckpointConflictError, 'effect head start lost' unless tx.changes == 1

          EffectTransitionLog.append!(
            tx,
            effect_key:,
            transition: 'start',
            attempt_number: row.fetch(0),
            actor: nil,
            evidence: {},
            now:
          )
        end
        @record_reader.fetch(effect_key)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
    end

    private_constant :EffectLifecycle
  end
end
