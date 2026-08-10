# frozen_string_literal: true

module Tamoz
  module SQLite
    # :nodoc: Read-only request row queries shared by the inbox operations.
    # :reek:DataClump :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyStatements :reek:UtilityFunction -- durable row shapes stay explicit.
    class RequestInboxRows
      REQUEST_SELECT = <<~SQL.lines.map(&:strip).join(' ').freeze
        SELECT thread_id, namespace, request_id, enqueue_sequence,
               input_digest, operation, delivery_mode, status, payload,
               payload_digest, execution_id, target_execution_id,
               cancellation_generation, checkpoint_id, response,
               response_digest, terminal_error, terminal_error_digest, retryable,
               created_at_ms, updated_at_ms
        FROM tamoz_requests
      SQL

      def initialize(store)
        @store = store
        freeze
      end

      def fetch_request(thread_id:, request_id:, namespace: [])
        thread, encoded_namespace = @store.normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = adapter.__send__(:read, operation: 'request.fetch') do |tx|
          request_row(tx, thread, encoded_namespace, id, 'request.fetch')
        end
        row && materialize_request(row)
      end

      # Ordered, durable request inbox history for one thread namespace.
      def request_history(thread_id:, namespace: [])
        thread, encoded_namespace = @store.normalize_address(thread_id, namespace)
        rows = adapter.__send__(:read, operation: 'request.history') do |tx|
          tx.rows(
            'request.history.select',
            <<~SQL,
              #{REQUEST_SELECT}
              WHERE thread_id = ? AND namespace = ?
              ORDER BY enqueue_sequence ASC
            SQL
            [thread, encoded_namespace]
          )
        end
        rows.map { |row| materialize_request(row) }.freeze
      end

      # Every (thread, namespace) with non-terminal request work, oldest first.
      def pending_threads(limit: 100)
        bounded = Integer(limit)
        raise ConfigurationError, 'limit must be positive' unless bounded.positive?

        rows = adapter.__send__(:read, operation: 'request.pending_threads') do |tx|
          pending_thread_rows(tx, bounded)
        end
        rows.map do |row|
          {
            thread_id: row.fetch(0),
            namespace: Wire.decode_namespace(row.fetch(1)),
            head_request_id: row.fetch(2),
            head_status: row.fetch(3).to_sym,
            enqueue_sequence: row.fetch(4)
          }.freeze
        end.freeze
      end

      # :nodoc: Used by writers so every request query shares one column order.
      def request_row(tx, thread_id, namespace, request_id, label) # rubocop:disable Naming/MethodParameterName
        tx.first(
          label,
          <<~SQL,
            #{REQUEST_SELECT}
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
          SQL
          [thread_id, namespace, request_id]
        )
      end

      private

      def adapter = @store.adapter
      def materialize_request(row) = @store.wire.materialize_request(row)

      def pending_thread_rows(tx, limit) # rubocop:disable Naming/MethodParameterName
        tx.rows(
          'request.pending_threads.select',
          <<~SQL,
            SELECT thread_id, namespace, request_id, status, enqueue_sequence
            FROM tamoz_requests AS outer_request
            WHERE status NOT IN ('completed', 'failed')
              AND enqueue_sequence = (
                SELECT MIN(enqueue_sequence) FROM tamoz_requests AS inner_request
                WHERE inner_request.thread_id = outer_request.thread_id
                  AND inner_request.namespace = outer_request.namespace
                  AND inner_request.status NOT IN ('completed', 'failed')
              )
            ORDER BY enqueue_sequence ASC
            LIMIT ?
          SQL
          [limit]
        )
      end
    end
  end
end
