# frozen_string_literal: true

require 'json'
require 'securerandom'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Records a lease-aware, explicitly authorized tombstone intent atomically.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall
    # :reek:FeatureEnvy :reek:LongParameterList :reek:MissingSafeMethod
    # :reek:TooManyStatements :reek:UtilityFunction
    # The repeated transaction, fence, and authorization values are one safety
    # boundary; splitting them would make the irreversible state change opaque.
    class ThreadTombstone
      def initialize(adapter:)
        @adapter = adapter
        @reports = DeletionReportCodec.new
      end

      def call(thread_id:, expected_tips:, authorization:)
        thread = Wire.identity(thread_id, name: 'thread id')
        validate_authorization!(authorization)
        normalized_tips = ThreadDeletionQueries.normalize_expected_tips(expected_tips)
        authorization_payload = ThreadDeletionQueries.authorization_payload(authorization)
        tombstone_id = SecureRandom.uuid.freeze
        context = {
          thread:,
          normalized_tips:,
          authorization:,
          authorization_payload:,
          tombstone_id:
        }

        adapter.__send__(:transaction, operation: 'thread.tombstone') do |transaction|
          tombstone(transaction, context)
        end
      end

      private

      attr_reader :adapter, :reports

      def validate_authorization!(authorization)
        return if authorization.is_a?(DeletionAuthorization)

        raise ConfigurationError,
              'tombstone requires a Tamoz::SQLite::DeletionAuthorization'
      end

      def tombstone(transaction, context)
        thread = context.fetch(:thread)
        normalized_tips = context.fetch(:normalized_tips)
        authorization_payload = context.fetch(:authorization_payload)
        now = adapter.__send__(:backend_time, transaction, 'thread.tombstone.time')
        existing = existing_tombstone(transaction, thread)
        return existing_report(existing, normalized_tips, authorization_payload) if existing

        create_tombstone!(transaction, context, now)
      end

      def create_tombstone!(transaction, context, now)
        thread, normalized_tips, authorization = context.values_at(
          :thread, :normalized_tips, :authorization
        )
        validate_thread!(transaction, thread, normalized_tips, authorization, now)
        unresolved = unresolved_effects(transaction, thread)
        abandon_effects!(transaction, unresolved, authorization, now)
        counts = ThreadDeletionQueries.counts(transaction, thread, 'thread.tombstone')
        report = build_report(thread, context.fetch(:tombstone_id), counts, unresolved, now)
        persist_new_tombstone!(transaction, context, report, now)
        reports.decode_report(report.fetch(0), digest: report.fetch(1))
      end

      def persist_new_tombstone!(transaction, context, report, now)
        thread, normalized_tips, authorization_payload, tombstone_id = context.values_at(
          :thread, :normalized_tips, :authorization_payload, :tombstone_id
        )
        report_bytes, report_digest, purge_after = report
        ThreadDeletionQueries.insert_tombstone!(
          transaction,
          {
            thread:,
            tombstone_id:,
            normalized_tips:,
            authorization_payload:,
            report_bytes:,
            report_digest:,
            now:,
            purge_after:
          }
        )
        ThreadDeletionQueries.block_thread!(transaction, thread, tombstone_id, now)
      end

      def existing_tombstone(transaction, thread)
        transaction.first(
          'thread.tombstone.existing',
          <<~SQL,
            SELECT t.tombstone_id, t.expected_tips, t.authorization, t.report,
                   t.report_digest, t.created_at_ms, t.purge_after_ms
            FROM tamoz_thread_tombstones t
            WHERE t.thread_id = ?
          SQL
          [thread]
        )
      end

      def existing_report(row, normalized_tips, authorization_payload)
        unless row.fetch(1) == JSON.generate(normalized_tips) &&
               row.fetch(2) == JSON.generate(authorization_payload)
          raise CheckpointConflictError,
                'thread already has a different tombstone intent'
        end
        reports.decode_report(row.fetch(3), digest: row.fetch(4))
      end

      def validate_thread!(transaction, thread, normalized_tips, authorization, now)
        thread_row = transaction.first(
          'thread.tombstone.thread',
          'SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?',
          [thread]
        )
        raise CheckpointConflictError, 'thread does not exist' unless thread_row
        raise CheckpointConflictError, 'thread is already tombstoned' if thread_row.fetch(0)

        validate_namespaces!(transaction, thread, normalized_tips, authorization, now)
      end

      def validate_namespaces!(transaction, thread, normalized_tips, authorization, now)
        namespaces = transaction.rows(
          'thread.tombstone.namespaces',
          <<~SQL,
            SELECT namespace, active_checkpoint_id, lease_fence,
                   lease_owner_id, lease_expires_at_ms
            FROM tamoz_namespaces
            WHERE thread_id = ?
            ORDER BY namespace COLLATE BINARY
          SQL
          [thread]
        )
        actual_tips = namespaces.to_h { |row| [row.fetch(0), row.fetch(1)] }
        raise CheckpointConflictError, 'thread checkpoint tips changed' unless actual_tips == normalized_tips

        validate_live_leases!(namespaces, authorization, now)
      end

      def validate_live_leases!(namespaces, authorization, now)
        namespaces.each do |namespace, _active_checkpoint_id,
                            lease_fence, lease_owner_id, lease_expires_at_ms|
          next unless lease_owner_id && lease_expires_at_ms && lease_expires_at_ms > now
          next if authorization.lease_fences.fetch(namespace, nil) == lease_fence

          raise CheckpointConflictError,
                'live lease requires its exact current fence'
        end
      end

      def unresolved_effects(transaction, thread)
        transaction.rows(
          'thread.tombstone.effects',
          <<~SQL,
            SELECT effect_key, current_attempt
            FROM tamoz_effects
            WHERE thread_id = ?
              AND status IN ('prepared', 'running', 'unknown', 'reconcile')
            ORDER BY effect_key
          SQL
          [thread]
        )
      end

      def abandon_effects!(transaction, unresolved, authorization, now)
        unresolved.each do |effect_key, attempt_number|
          abandon_effect!(transaction, effect_key, attempt_number, authorization, now)
        end
      end

      def abandon_effect!(transaction, effect_key, attempt_number, authorization, now)
        ThreadDeletionQueries.abandon_effect!(
          transaction,
          effect_key:,
          attempt_number:,
          authorization:,
          now:
        )
      end

      def build_report(thread, tombstone_id, counts, unresolved, now)
        purge_after = now + (adapter.limits.deletion_retention * 1_000).ceil
        report_hash = {
          'thread_id' => thread,
          'tombstone_id' => tombstone_id,
          'status' => 'active',
          'counts' => counts,
          'abandoned_effect_keys' => unresolved.map(&:first),
          'created_at_ms' => now,
          'purge_after_ms' => purge_after
        }
        bytes = JSON.generate(report_hash)
        [
          bytes,
          Wire.digest(bytes, domain: 'tamoz.sqlite.tombstone_report'),
          purge_after
        ]
      end
    end
    private_constant :ThreadTombstone
  end
end
