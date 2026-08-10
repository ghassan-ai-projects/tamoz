# frozen_string_literal: true

module Tamoz
  # SQLite checkpoint collaborators keep the persistence boundary explicit.
  module SQLite
    # Owns the non-active checkpoint deletion transaction.
    # :reek:FeatureEnvy :reek:NestedIterators :reek:NilCheck :reek:TooManyStatements
    # Candidate selection and deletion stay in one ordered transaction because
    # the guards are the pruning safety contract.
    class CheckpointPruner
      def initialize(store:)
        @store = store
        freeze
      end

      # The candidate read and deletes share one transaction so pruning cannot
      # remove a row after the active-chain or pending/request guards go stale.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
      def prune(thread:, encoded_namespace:, keep:)
        deleted_ids = []
        created_at = nil
        adapter.__send__(:transaction, operation: 'checkpoint.prune') do |tx|
          created_at = adapter.__send__(:backend_time, tx, 'checkpoint.prune.time')
          tombstone = tx.scalar(
            'checkpoint.prune.thread',
            'SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?',
            [thread]
          )
          raise CheckpointConflictError, 'thread does not exist' if tombstone.nil? &&
                                                                    !tx.first(
                                                                      'checkpoint.prune.exists',
                                                                      'SELECT 1 FROM tamoz_threads WHERE thread_id = ?',
                                                                      [thread]
                                                                    )
          raise CheckpointConflictError, 'thread is tombstoned' if tombstone

          candidates = tx.rows(
            'checkpoint.prune.candidates',
            <<~SQL,
              WITH RECURSIVE
              active_chain(id) AS (
                SELECT active_checkpoint_id
                FROM tamoz_namespaces
                WHERE thread_id = ? AND namespace = ?
                UNION ALL
                SELECT c.parent_id
                FROM tamoz_checkpoints c
                JOIN active_chain a ON c.id = a.id
                WHERE c.parent_id IS NOT NULL
              ),
              newest(id) AS (
                SELECT id
                FROM tamoz_checkpoints
                WHERE thread_id = ? AND namespace = ?
                ORDER BY sequence DESC
                LIMIT ?
              )
              SELECT c.id
              FROM tamoz_checkpoints c
              WHERE c.thread_id = ? AND c.namespace = ?
                AND c.id NOT IN (SELECT id FROM active_chain WHERE id IS NOT NULL)
                AND c.id NOT IN (SELECT id FROM newest)
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_pending_activations p
                  WHERE p.base_checkpoint_id = c.id OR p.consumed_by = c.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_requests r WHERE r.checkpoint_id = c.id
                )
              ORDER BY c.sequence DESC
            SQL
            [
              thread, encoded_namespace, thread, encoded_namespace, keep,
              thread, encoded_namespace
            ]
          ).flatten
          candidates.each do |id|
            tx.execute(
              'checkpoint.prune.delete',
              <<~SQL,
                DELETE FROM tamoz_checkpoints
                WHERE id = ? AND thread_id = ? AND namespace = ?
              SQL
              [id, thread, encoded_namespace]
            )
            deleted_ids << id.freeze if tx.changes == 1
          end
        end
        PruneReport.new(
          thread_id: thread,
          namespace: Wire.decode_namespace(encoded_namespace),
          kept_minimum: keep,
          deleted_checkpoint_ids: deleted_ids.freeze,
          created_at_ms: created_at
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength

      private

      def adapter = @store.adapter
    end

    private_constant :CheckpointPruner
  end
end
