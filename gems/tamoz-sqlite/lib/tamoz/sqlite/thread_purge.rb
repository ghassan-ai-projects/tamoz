# frozen_string_literal: true

require 'json'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Permanently removes a previously tombstoned thread in one fenced transaction.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:LongParameterList :reek:MissingSafeMethod :reek:TooManyStatements
    # :reek:UtilityFunction -- row fields and transaction arguments are the durable
    # purge contract; the bang helpers enforce irreversible deletion preconditions.
    class ThreadPurge
      def initialize(adapter:)
        @adapter = adapter
        @reports = DeletionReportCodec.new
      end

      def call(tombstone_id:)
        id = Wire.identity(tombstone_id, name: 'tombstone id')
        receipt = nil
        adapter.__send__(:transaction, operation: 'thread.purge') do |transaction|
          receipt = purge(transaction, id)
        end
        receipt
      end

      private

      def purge(transaction, id)
        now = adapter.__send__(:backend_time, transaction, 'thread.purge.time')
        existing = existing_receipt(transaction, id)
        return reports.decode_receipt(id, existing) if existing

        purge_new_thread(transaction, id, now)
      end

      def purge_new_thread(transaction, id, now)
        row = active_tombstone(transaction, id)
        thread = ensure_purgeable!(transaction, row, now)
        counts = ThreadDeletionQueries.counts(transaction, thread, 'thread.purge')
        delete_comms_rows!(transaction, thread)
        final_report, report_digest = build_final_report(row, counts, now)
        thread_digest = Wire.digest(thread, domain: 'tamoz.sqlite.deleted_thread')
        ThreadDeletionQueries.insert_receipt!(
          transaction,
          {
            id:,
            thread_digest:,
            report: final_report,
            report_digest:,
            now:
          }
        )
        delete_thread!(transaction, thread, id)
        build_receipt(thread_digest, id, report_digest, now, counts)
      end

      def build_receipt(thread_digest, id, report_digest, now, counts)
        DeletionReceipt.new(
          thread_id_digest: thread_digest.freeze,
          tombstone_id: id,
          report_digest: report_digest.freeze,
          purged_at_ms: now,
          counts: counts.freeze
        )
      end

      def existing_receipt(transaction, id)
        transaction.first(
          'thread.purge.receipt',
          <<~SQL,
            SELECT thread_id_digest, report, report_digest, purged_at_ms
            FROM tamoz_deletion_receipts
            WHERE tombstone_id = ?
          SQL
          [id]
        )
      end

      def active_tombstone(transaction, id)
        row = transaction.first(
          'thread.purge.tombstone',
          <<~SQL,
            SELECT thread_id, report, report_digest, purge_after_ms
            FROM tamoz_thread_tombstones
            WHERE tombstone_id = ? AND status = 'active'
          SQL
          [id]
        )
        raise CheckpointConflictError, 'active tombstone does not exist' unless row

        row
      end

      def ensure_purgeable!(transaction, row, now)
        thread = row.fetch(0)
        raise CheckpointConflictError, 'thread retention window has not expired' if row.fetch(3) && now < row.fetch(3)

        unresolved = transaction.scalar(
          'thread.purge.unresolved',
          <<~SQL,
            SELECT COUNT(*)
            FROM tamoz_effects
            WHERE thread_id = ?
              AND status IN ('prepared', 'running', 'unknown', 'reconcile')
          SQL
          [thread]
        )
        raise CheckpointConflictError, 'thread still has unresolved effects' if unresolved.positive?

        thread
      end

      def build_final_report(row, counts, now)
        Wire.verify_digest!(
          row.fetch(1),
          row.fetch(2),
          domain: 'tamoz.sqlite.tombstone_report'
        )
        report_hash = JSON.parse(row.fetch(1), create_additions: false)
        final_report = JSON.generate(
          report_hash.merge(
            'status' => 'purged',
            'purged_at_ms' => now,
            'purged_counts' => counts
          )
        )
        [
          final_report,
          Wire.digest(final_report, domain: 'tamoz.sqlite.deletion_report')
        ]
      end

      def delete_thread!(transaction, thread, id)
        transaction.execute(
          'thread.purge.delete',
          'DELETE FROM tamoz_threads WHERE thread_id = ? AND tombstone_id = ?',
          [thread, id]
        )
        raise CheckpointConflictError, 'thread purge lost' unless transaction.changes == 1
      end

      # Invariant 54: comms rows are deleted EXPLICITLY — no comms table has a
      # foreign key to tamoz_threads, so cascade alone would leave orphaned
      # conversations, outbox rows, requests, decisions and prompts. One
      # statement per table is the deletion contract.
      # rubocop:disable Metrics/MethodLength
      def delete_comms_rows!(transaction, thread)
        routes = transaction.rows(
          'thread.purge.comms.routes',
          <<~SQL,
            SELECT surface_id, conversation_id FROM tamoz_comms_conversations WHERE thread_id = ?
          SQL
          [thread]
        )
        routes.each do |route|
          transaction.execute(
            'thread.purge.comms.outbox',
            <<~SQL,
              DELETE FROM tamoz_comms_outbox WHERE surface_id = ? AND conversation_id = ?
            SQL
            [route[0], route[1]]
          )
          transaction.execute(
            'thread.purge.comms.inbound',
            <<~SQL,
              DELETE FROM tamoz_comms_inbound WHERE surface_id = ? AND conversation_id = ?
            SQL
            [route[0], route[1]]
          )
        end
        transaction.execute(
          'thread.purge.comms.routes.delete',
          'DELETE FROM tamoz_comms_conversations WHERE thread_id = ?',
          [thread]
        )
        transaction.execute(
          'thread.purge.comms.requests.delete',
          'DELETE FROM tamoz_comms_requests WHERE thread_id = ?',
          [thread]
        )
        transaction.execute(
          'thread.purge.comms.decisions.delete',
          'DELETE FROM tamoz_comms_decisions WHERE thread_id = ?',
          [thread]
        )
        transaction.execute(
          'thread.purge.comms.prompts.delete',
          'DELETE FROM tamoz_comms_approval_prompts WHERE thread_id = ?',
          [thread]
        )
      end
      # rubocop:enable Metrics/MethodLength

      public

      def receipt(tombstone_id:)
        id = Wire.identity(tombstone_id, name: 'tombstone id')
        row = adapter.__send__(:read, operation: 'thread.deletion_receipt') do |tx|
          tx.first(
            'thread.deletion_receipt',
            <<~SQL,
              SELECT thread_id_digest, report, report_digest, purged_at_ms
              FROM tamoz_deletion_receipts
              WHERE tombstone_id = ?
            SQL
            [id]
          )
        end
        row && reports.decode_receipt(id, row)
      end

      private

      attr_reader :adapter, :reports
    end

    private_constant :ThreadPurge
  end
end
