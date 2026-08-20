# frozen_string_literal: true

require 'securerandom'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Owns evidence-backed reconciliation and human effect resolution.
    # :reek:DuplicateMethodCall -- repeated row and lease reads are the exact
    # durable predicates for evidence and fencing.
    # :reek:TooManyStatements -- each disposition stays visible inside the
    # single atomic reconciliation transaction.
    # :reek:LongParameterList -- evidence and audit identity are the public
    # reconciliation and resolution contract.
    # :reek:RepeatedConditional -- each changes check guards a different CAS.
    class EffectReconciler
      def initialize(store:, guard:, attempt_ttl:, record_reader:)
        @store = store
        @guard = guard
        @attempt_ttl = attempt_ttl
        @record_reader = record_reader
        freeze
      end

      # Resolve a reconcile head from observed target evidence. Only not_applied
      # grants a new fenced attempt; the other dispositions record truth after lease
      # loss without granting execution authority.
      # The disposition branches remain in one transaction so only the
      # not_applied branch can grant a fenced retry.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
      def reconcile(key:, disposition:, actor:, evidence:)
        effect_key = Wire.identity(key, name: 'effect key')
        disposition_text = EffectJournalValidation.enum_text!(
          disposition,
          %w[completed not_applied unknown],
          'effect reconciliation disposition'
        )
        actor_text = Wire.identity(actor, name: 'effect reconciliation actor')
        evidence_bytes = @store.checkpoint_codec.state_codec.dump(evidence)
        evidence_digest = Wire.digest(
          evidence_bytes,
          domain: 'tamoz.sqlite.effect_reconciliation'
        )
        candidate_token = SecureRandom.uuid.freeze
        action = nil
        granted_token = nil

        @store.adapter.__send__(:transaction, operation: 'effect.reconcile') do |tx|
          now = @store.adapter.__send__(:backend_time, tx, 'effect.reconcile.time')
          row = EffectJournalRows.effect(tx, effect_key, 'effect.reconcile.row')
          raise CheckpointConflictError, 'effect does not exist' unless row
          unless row.fetch(9) == 'reconcile'
            raise CheckpointConflictError,
                  "effect status #{row.fetch(9)} cannot be reconciled"
          end

          case disposition_text
          when 'completed'
            tx.execute(
              'effect.reconcile.completed_attempt',
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'succeeded', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running', 'unknown')
              SQL
              [now, effect_key, row.fetch(11)]
            )
            tx.execute(
              'effect.reconcile.completed_head',
              <<~SQL,
                UPDATE tamoz_effects
                SET status = 'succeeded', requires_reconciliation = 0, updated_at_ms = ?
                WHERE effect_key = ? AND status = 'reconcile'
              SQL
              [now, effect_key]
            )
            raise CheckpointConflictError, 'effect reconciliation lost' unless tx.changes == 1

            action = :return
          when 'not_applied'
            @store.adapter.__send__(
              :validate_lease_in_transaction!,
              tx,
              @guard.lease,
              now:,
              label: 'effect.reconcile.lease'
            )
            tx.execute(
              'effect.reconcile.not_applied_attempt',
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'abandoned', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running', 'unknown')
              SQL
              [now, effect_key, row.fetch(11)]
            )
            EffectAttemptLedger.grant_next!(
              tx,
              row:,
              effect_key:,
              token: candidate_token,
              execution_id: row.fetch(4),
              fence: @guard.lease.fence,
              attempt_ttl: @attempt_ttl,
              now:
            )
            tx.execute(
              'effect.reconcile.not_applied_head',
              <<~SQL,
                UPDATE tamoz_effects
                SET requires_reconciliation = 0, updated_at_ms = ?
                WHERE effect_key = ?
              SQL
              [now, effect_key]
            )
            action = :execute
            granted_token = candidate_token
          else
            tx.execute(
              'effect.reconcile.unknown_attempt',
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'unknown', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running')
              SQL
              [now, effect_key, row.fetch(11)]
            )
            tx.execute(
              'effect.reconcile.unknown_head',
              <<~SQL,
                UPDATE tamoz_effects
                SET status = 'unknown', requires_reconciliation = 1, updated_at_ms = ?
                WHERE effect_key = ? AND status = 'reconcile'
              SQL
              [now, effect_key]
            )
            raise CheckpointConflictError, 'effect reconciliation lost' unless tx.changes == 1

            action = :unknown
          end

          EffectTransitionLog.append!(
            tx,
            effect_key:,
            transition: "reconcile.#{disposition_text}",
            attempt_number: row.fetch(11),
            actor: actor_text,
            evidence: {
              'payload' => evidence_bytes,
              'payload_digest' => evidence_digest
            },
            now:
          )
        end

        Tamoz::Graph::EffectDecision.new(
          action:,
          record: @record_reader.fetch(effect_key),
          attempt_token: granted_token
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength

      # Human resolution updates the head and its audit transition atomically.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
      def resolve(key:, status:, actor:, evidence:)
        effect_key = Wire.identity(key, name: 'effect key')
        status_text = EffectJournalValidation.enum_text!(
          status,
          %w[succeeded failed abandoned],
          'effect resolution status'
        )
        actor_text = Wire.identity(actor, name: 'effect resolution actor')
        evidence_bytes = @store.checkpoint_codec.state_codec.dump(evidence)

        @store.adapter.__send__(:transaction, operation: 'effect.resolve') do |tx|
          now = @store.adapter.__send__(:backend_time, tx, 'effect.resolve.time')
          row = EffectJournalRows.effect(tx, effect_key, 'effect.resolve.row')
          raise CheckpointConflictError, 'effect does not exist' unless row
          unless %w[unknown reconcile failed].include?(row.fetch(9))
            raise CheckpointConflictError,
                  "effect status #{row.fetch(9)} cannot be human-resolved"
          end
          tx.execute(
            'effect.resolve.head',
            <<~SQL,
              UPDATE tamoz_effects
              SET status = ?,
                  requires_reconciliation = CASE WHEN ? = 'succeeded' THEN 0 ELSE
                    requires_reconciliation END,
                  updated_at_ms = ?
              WHERE effect_key = ? AND status = ?
            SQL
            [status_text, status_text, now, effect_key, row.fetch(9)]
          )
          raise CheckpointConflictError, 'effect resolution lost' unless tx.changes == 1

          EffectTransitionLog.append!(
            tx,
            effect_key:,
            transition: "resolve.#{status_text}",
            attempt_number: row.fetch(11),
            actor: actor_text,
            evidence: {
              'payload' => evidence_bytes,
              'payload_digest' => Wire.digest(
                evidence_bytes,
                domain: 'tamoz.sqlite.effect_resolution'
              )
            },
            now:
          )
        end
        @record_reader.fetch(effect_key)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
    end

    private_constant :EffectReconciler
  end
end
