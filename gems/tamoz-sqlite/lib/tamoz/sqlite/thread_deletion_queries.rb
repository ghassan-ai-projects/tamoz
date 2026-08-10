# frozen_string_literal: true

require 'json'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Shared SQL fragments for the atomic tombstone and purge transactions.
    # :reek:LongParameterList :reek:TooManyStatements
    # The parameters are the transaction's explicit fence, identity, and report
    # fields; keeping them named preserves the deletion protocol at each call site.
    class ThreadDeletionQueries
      def self.normalize_expected_tips(value)
        raise ConfigurationError, 'expected_tips must be a Hash' unless value.is_a?(Hash)

        value.each_with_object({}) do |(namespace, checkpoint_id), result|
          encoded = Wire.namespace(namespace)
          id = checkpoint_id &&
               Wire.identity(checkpoint_id, name: 'expected checkpoint id')
          raise ConfigurationError, 'duplicate expected namespace' if result.key?(encoded)

          result[encoded] = id
        end.sort.to_h.freeze
      end

      def self.authorization_payload(authorization)
        {
          'actor' => authorization.actor,
          'reason_digest' => Wire.digest(
            authorization.reason,
            domain: 'tamoz.sqlite.deletion_reason'
          ),
          'effect_decisions' => authorization.effect_decisions.sort.to_h,
          'lease_fences' => authorization.lease_fences.sort.to_h
        }.freeze
      end

      def self.counts(transaction, thread, prefix)
        {
          'namespaces' => count(transaction, thread, prefix, 'namespaces'),
          'checkpoints' => count(transaction, thread, prefix, 'checkpoints'),
          'requests' => count(transaction, thread, prefix, 'requests'),
          'effects' => count(transaction, thread, prefix, 'effects')
        }.freeze
      end

      def self.count(transaction, thread, prefix, table)
        transaction.scalar(
          "#{prefix}.count.#{table}",
          "SELECT COUNT(*) FROM tamoz_#{table} WHERE thread_id = ?",
          [thread]
        )
      end

      def self.append_effect_transition!(transaction, effect_key:, attempt_number:, authorization:, now:)
        index = transition_index(transaction, effect_key)
        evidence = transition_evidence(authorization)
        transaction.execute(
          'thread.tombstone.effect_transition',
          <<~SQL,
            INSERT INTO tamoz_effect_transitions(
              effect_key, transition_index, transition, attempt_number,
              actor, evidence, created_at_ms
            )
            VALUES (?, ?, 'deletion.abandon', ?, ?, ?, ?)
          SQL
          [
            effect_key, index, attempt_number, authorization.actor,
            Wire.blob(evidence), now
          ]
        )
      end

      def self.abandon_effect!(transaction, effect_key:, attempt_number:, authorization:, now:)
        verify_abandonment!(effect_key, authorization)
        abandon_effect_attempt!(transaction, effect_key, attempt_number, now)
        abandon_effect_state!(transaction, effect_key, now)
        append_effect_transition!(
          transaction,
          effect_key:,
          attempt_number:,
          authorization:,
          now:
        )
      end

      def self.verify_abandonment!(effect_key, authorization)
        return if authorization.effect_decisions.fetch(effect_key, nil) == 'abandon'

        raise CheckpointConflictError,
              'unresolved effect requires explicit abandonment'
      end

      def self.abandon_effect_attempt!(transaction, effect_key, attempt_number, now)
        transaction.execute(
          'thread.tombstone.effect_attempt',
          <<~SQL,
            UPDATE tamoz_effect_attempts
            SET status = 'abandoned', completed_at_ms = COALESCE(completed_at_ms, ?)
            WHERE effect_key = ? AND attempt_number = ?
              AND status IN ('prepared', 'running', 'unknown')
          SQL
          [now, effect_key, attempt_number]
        )
      end

      def self.abandon_effect_state!(transaction, effect_key, now)
        transaction.execute(
          'thread.tombstone.effect',
          <<~SQL,
            UPDATE tamoz_effects
            SET status = 'abandoned', updated_at_ms = ?
            WHERE effect_key = ?
              AND status IN ('prepared', 'running', 'unknown', 'reconcile')
          SQL
          [now, effect_key]
        )
      end

      def self.transition_index(transaction, effect_key)
        transaction.scalar(
          'thread.tombstone.effect_transition_index',
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_effect_transitions
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
      end

      def self.transition_evidence(authorization)
        JSON.generate(
          'reason_digest' => Wire.digest(
            authorization.reason,
            domain: 'tamoz.sqlite.deletion_reason'
          )
        )
      end

      def self.insert_tombstone!(transaction, tombstone)
        transaction.execute(
          'thread.tombstone.insert',
          <<~SQL,
            INSERT INTO tamoz_thread_tombstones(
              thread_id, tombstone_id, expected_tips, status, effect_policy,
              authorization, report, report_digest, created_at_ms, purge_after_ms
            )
            VALUES (?, ?, ?, 'active', 'explicit', ?, ?, ?, ?, ?)
          SQL
          [
            tombstone.fetch(:thread), tombstone.fetch(:tombstone_id),
            Wire.blob(JSON.generate(tombstone.fetch(:normalized_tips))),
            Wire.blob(JSON.generate(tombstone.fetch(:authorization_payload))),
            Wire.blob(tombstone.fetch(:report_bytes)), tombstone.fetch(:report_digest),
            tombstone.fetch(:now), tombstone.fetch(:purge_after)
          ]
        )
      end

      def self.block_thread!(transaction, thread, tombstone_id, now)
        transaction.execute(
          'thread.tombstone.block',
          <<~SQL,
            UPDATE tamoz_threads
            SET tombstone_id = ?, updated_at_ms = ?
            WHERE thread_id = ? AND tombstone_id IS NULL
          SQL
          [tombstone_id, now, thread]
        )
        raise CheckpointConflictError, 'thread tombstone lost' unless transaction.changes == 1
      end

      def self.insert_receipt!(transaction, receipt)
        transaction.execute(
          'thread.purge.insert_receipt',
          <<~SQL,
            INSERT INTO tamoz_deletion_receipts(
              tombstone_id, thread_id_digest, report, report_digest, purged_at_ms
            )
            VALUES (?, ?, ?, ?, ?)
          SQL
          [
            receipt.fetch(:id), receipt.fetch(:thread_digest),
            Wire.blob(receipt.fetch(:report)), receipt.fetch(:report_digest),
            receipt.fetch(:now)
          ]
        )
      end
    end

    private_constant :ThreadDeletionQueries
  end
end
