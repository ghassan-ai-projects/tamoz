# frozen_string_literal: true

module Tamoz
  # SQLite checkpoint collaborators keep the persistence boundary explicit.
  module SQLite
    # Read-side checkpoint queries, including durable pending-outcome reconciliation.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:InstanceVariableAssumption
    # :reek:LongParameterList :reek:NestedIterators :reek:TooManyStatements
    # These methods preserve the established row shapes, query order, and separate
    # reconciliation reads; carriers or query abstraction would hide those contracts.
    class CheckpointQueries
      def initialize(store:)
        @store = store
        freeze
      end

      def latest(thread_id:, namespace: [], validate_identity: true)
        address = @store.normalize_address(thread_id, namespace)
        row = adapter.__send__(:read, operation: 'checkpoint.latest') do |tx|
          tx.first(
            'checkpoint.latest',
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_namespaces n
              LEFT JOIN tamoz_checkpoints c
                ON c.id = n.active_checkpoint_id
              WHERE n.thread_id = ? AND n.namespace = ?
            SQL
            address
          )
        end
        # Preserve the original nil/false guard rather than changing its return value.
        return nil unless row && row.fetch(0) # rubocop:disable Style/SafeNavigation

        @store.materialize(row, validate_identity:)
      end

      def latest_graph_version(thread_id:, namespace: [])
        address = @store.normalize_address(thread_id, namespace)
        adapter.__send__(:read, operation: 'checkpoint.latest_graph_version') do |tx|
          tx.scalar(
            'checkpoint.latest_graph_version',
            <<~SQL,
              SELECT c.graph_version
              FROM tamoz_namespaces n
              LEFT JOIN tamoz_checkpoints c
                ON c.id = n.active_checkpoint_id
              WHERE n.thread_id = ? AND n.namespace = ?
            SQL
            address
          )
        end
      end

      def find(thread_id:, checkpoint_id:, namespace: [])
        address = @store.normalize_address(thread_id, namespace)
        id = Wire.identity(checkpoint_id, name: 'checkpoint id')
        row = adapter.__send__(:read, operation: 'checkpoint.find') do |tx|
          tx.first(
            'checkpoint.find',
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_checkpoints c
              JOIN tamoz_namespaces n
                ON n.thread_id = c.thread_id AND n.namespace = c.namespace
              WHERE c.thread_id = ? AND c.namespace = ? AND c.id = ?
            SQL
            [*address, id]
          )
        end
        row && @store.materialize(row)
      end

      # The validation and SELECT bind construction stay before the read to preserve
      # the original failure and query ordering.
      # rubocop:disable Metrics/MethodLength
      def history(thread_id:, limit:, namespace: [], before_sequence: nil)
        address = @store.normalize_address(thread_id, namespace)
        normalized_limit = history_limit(limit)
        if before_sequence &&
           (!before_sequence.is_a?(Integer) || before_sequence.negative?)
          raise ConfigurationError,
                'before_sequence must be a non-negative integer'
        end
        comparison = before_sequence ? 'AND c.sequence < ?' : ''
        binds = [*address]
        binds << before_sequence if before_sequence
        binds << normalized_limit
        rows = adapter.__send__(:read, operation: 'checkpoint.history') do |tx|
          tx.rows(
            'checkpoint.history',
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_checkpoints c
              JOIN tamoz_namespaces n
                ON n.thread_id = c.thread_id AND n.namespace = c.namespace
              WHERE c.thread_id = ? AND c.namespace = ?
                #{comparison}
              ORDER BY c.sequence DESC
              LIMIT ?
            SQL
            binds
          )
        end
        rows.map { |row| @store.materialize(row) }.freeze
      end
      # rubocop:enable Metrics/MethodLength

      # BoundarySourceAudit follows tx-named helpers across this read seam.
      # rubocop:disable Naming/MethodParameterName
      def decode_latest_checkpoint_in_transaction(tx, thread_id, namespace, label)
        row = tx.first(
          label,
          <<~SQL,
            SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                   c.format_version, c.execution_id, c.graph_name,
                   c.graph_version, c.definition_digest, c.status,
                   c.payload, c.payload_digest, n.active_checkpoint_id
            FROM tamoz_namespaces n
            LEFT JOIN tamoz_checkpoints c
              ON c.id = n.active_checkpoint_id
            WHERE n.thread_id = ? AND n.namespace = ?
          SQL
          [thread_id, namespace]
        )
        # Keep the original false/nil short-circuit semantics.
        row && row.fetch(0) && wire.decode_checkpoint_row(row) # rubocop:disable Style/SafeNavigation
      end
      # rubocop:enable Naming/MethodParameterName

      def materialize(row, validate_identity: true)
        durable_pending = if row.fetch(0) == row.fetch(13)
                            @store.pending_outcomes(
                              thread_id: row.fetch(2),
                              namespace: row.fetch(3),
                              execution_id: row.fetch(6)
                            )
                          end
        wire.materialize(row, durable_pending:, validate_identity:)
      end

      # These are deliberately separate read barriers; changing them to a JOIN or
      # transaction would change the durable pending-outcome query contract.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
      def pending_outcomes(thread_id:, namespace:, execution_id:)
        activation_rows = adapter.__send__(
          :read,
          operation: 'checkpoint.pending'
        ) do |tx|
          tx.rows(
            'checkpoint.pending.activations',
            <<~SQL,
              SELECT task_id, attempt_id, base_checkpoint_id, node, path,
                     outcome_digest
              FROM tamoz_pending_activations
              WHERE thread_id = ? AND namespace = ?
                AND execution_id = ? AND consumed_by IS NULL
              ORDER BY task_id
            SQL
            [thread_id, namespace, execution_id]
          )
        end
        activation_rows.to_h do |activation|
          task_id = activation.fetch(0)
          write_rows = adapter.__send__(
            :read,
            operation: 'checkpoint.pending_writes'
          ) do |tx|
            tx.rows(
              'checkpoint.pending.writes',
              <<~SQL,
                SELECT write_index, kind, channel, payload, payload_digest
                FROM tamoz_pending_writes
                WHERE thread_id = ? AND namespace = ?
                  AND execution_id = ? AND task_id = ?
                ORDER BY write_index
              SQL
              [thread_id, namespace, execution_id, task_id]
            )
          end
          writes = write_rows.map do |write|
            payload = write.fetch(3)
            Wire.verify_digest!(
              payload,
              write.fetch(4),
              domain: 'tamoz.sqlite.pending_write'
            )
            {
              'write_index' => write.fetch(0),
              'kind' => write.fetch(1),
              'channel' => write.fetch(2),
              'payload' => payload
            }.freeze
          end
          metadata = {
            'task_id' => task_id,
            'attempt_id' => activation.fetch(1),
            'base_checkpoint_id' => activation.fetch(2),
            'node' => activation.fetch(3),
            'path' => activation.fetch(4)
          }.freeze
          outcome = checkpoint_codec.load_outcome(metadata:, writes:)
          Wire.verify_digest!(
            checkpoint_codec.dump_outcome(outcome),
            activation.fetch(5),
            domain: 'tamoz.sqlite.pending_outcome'
          )
          [task_id, outcome]
        end.freeze
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength

      private

      def adapter = @store.adapter
      def checkpoint_codec = @store.checkpoint_codec
      def history_limit(value) = @store.history_limit(value)
      def wire = @store.wire
    end

    private_constant :CheckpointQueries
  end
end
