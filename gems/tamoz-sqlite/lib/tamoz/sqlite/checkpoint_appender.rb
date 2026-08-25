# frozen_string_literal: true

require 'json'

module Tamoz
  # SQLite checkpoint collaborators keep the persistence boundary explicit.
  module SQLite
    # Atomically records a task's durable outcome and its pending writes.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:MissingSafeMethod :reek:NestedIterators :reek:TooManyStatements
    # The repeated values are the activation identity and wire columns; keeping
    # them visible preserves the existing validation and insert ordering.
    class CheckpointAppender
      def initialize(store:)
        @store = store
        freeze
      end

      # This method is one atomic pending-activation barrier; its ordered
      # validation, idempotency check, and inserts must remain together.
      # rubocop:disable Metrics/AbcSize -- one atomic pending-write barrier
      # rubocop:disable Metrics/CyclomaticComplexity -- one atomic pending-write barrier
      # rubocop:disable Metrics/MethodLength -- one atomic pending-write barrier
      # rubocop:disable Metrics/PerceivedComplexity -- one atomic pending-write barrier
      # rubocop:disable Metrics/BlockLength -- one atomic pending-write barrier
      def append_writes(lease:, task:, outcome:)
        unless task.id == outcome.task_id &&
               task.attempt_id == outcome.attempt_id &&
               task.base_checkpoint_id == outcome.base_checkpoint_id &&
               task.execution_id
          raise CheckpointConflictError, 'task outcome identity is stale or mismatched'
        end

        execution_id = Wire.identity(task.execution_id, name: 'execution id')
        task_id = Wire.identity(task.id, name: 'task id')
        attempt_id = Wire.identity(task.attempt_id, name: 'attempt id')
        base_id = Wire.identity(task.base_checkpoint_id, name: 'base checkpoint id')
        node = task.node.to_s
        path = JSON.generate(task.path).freeze
        outcome_bytes = checkpoint_codec.dump_outcome(outcome)
        outcome_digest = Wire.digest(
          outcome_bytes,
          domain: 'tamoz.sqlite.pending_outcome'
        )
        writes = checkpoint_codec.dump_outcome_writes(outcome).map do |write|
          payload = write.fetch('payload')
          write.merge(
            'payload_digest' => Wire.digest(
              payload,
              domain: 'tamoz.sqlite.pending_write'
            )
          ).freeze
        end.freeze

        result = :inserted
        adapter.__send__(:transaction, operation: 'checkpoint.append_writes') do |tx|
          now = adapter.__send__(:backend_time, tx, 'checkpoint.writes.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'checkpoint.writes.lease'
          )
          base_row = tx.first(
            'checkpoint.writes.base',
            <<~SQL,
              SELECT execution_id
              FROM tamoz_checkpoints
              WHERE id = ? AND thread_id = ? AND namespace = ?
            SQL
            [base_id, lease.thread_id, lease.namespace]
          )
          unless base_row && base_row.fetch(0) == execution_id
            raise CheckpointConflictError,
                  'pending write base or execution is incompatible'
          end

          existing = tx.first(
            'checkpoint.writes.existing',
            <<~SQL,
              SELECT attempt_id, base_checkpoint_id, node, path, outcome_digest
              FROM tamoz_pending_activations
              WHERE thread_id = ? AND namespace = ?
                AND execution_id = ? AND task_id = ?
            SQL
            [lease.thread_id, lease.namespace, execution_id, task_id]
          )
          if existing
            unless existing == [attempt_id, base_id, node, path, outcome_digest]
              raise CheckpointConflictError,
                    'logical activation already has a different durable outcome'
            end
            @store.verify_existing_writes!(
              tx,
              lease:,
              execution_id:,
              task_id:,
              writes:
            )
            result = :already_present
            next
          end

          tx.execute(
            'checkpoint.writes.activation',
            <<~SQL,
              INSERT INTO tamoz_pending_activations(
                thread_id, namespace, execution_id, task_id, attempt_id,
                base_checkpoint_id, node, path, outcome_digest, consumed_by,
                created_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            SQL
            [
              lease.thread_id, lease.namespace, execution_id, task_id,
              attempt_id, base_id, node, Wire.blob(path), outcome_digest, now
            ]
          )
          writes.each do |write|
            tx.execute(
              "checkpoint.writes.item.#{write.fetch('write_index')}",
              <<~SQL,
                INSERT INTO tamoz_pending_writes(
                  thread_id, namespace, execution_id, task_id, write_index,
                  kind, channel, payload, payload_digest
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              SQL
              [
                lease.thread_id, lease.namespace, execution_id, task_id,
                write.fetch('write_index'), write.fetch('kind'),
                write.fetch('channel'), Wire.blob(write.fetch('payload')),
                write.fetch('payload_digest')
              ]
            )
          end
        end
        result
      end
      # rubocop:enable Metrics/AbcSize
      # rubocop:enable Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength
      # rubocop:enable Metrics/PerceivedComplexity
      # rubocop:enable Metrics/BlockLength

      # The tx name is part of the source-audited boundary vocabulary.
      # rubocop:disable Metrics/MethodLength, Naming/MethodParameterName, Style/GuardClause
      def verify_pending_writes!(tx, lease:, execution_id:, task_id:, writes:)
        rows = tx.rows(
          'checkpoint.writes.verify',
          <<~SQL,
            SELECT write_index, kind, channel, payload, payload_digest
            FROM tamoz_pending_writes
            WHERE thread_id = ? AND namespace = ?
              AND execution_id = ? AND task_id = ?
            ORDER BY write_index
          SQL
          [lease.thread_id, lease.namespace, execution_id, task_id]
        )
        expected = writes.map do |write|
          [
            write.fetch('write_index'), write.fetch('kind'),
            write.fetch('channel'), write.fetch('payload'),
            write.fetch('payload_digest')
          ]
        end
        unless rows == expected
          raise CheckpointCorruptionError,
                'durable pending writes disagree with their activation digest'
        end
      end
      # rubocop:enable Metrics/MethodLength, Naming/MethodParameterName, Style/GuardClause

      private

      def adapter = @store.adapter
      def checkpoint_codec = @store.checkpoint_codec
    end

    private_constant :CheckpointAppender
  end
end
