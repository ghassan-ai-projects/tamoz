# frozen_string_literal: true

module Tamoz
  module SQLite
    # A read-only view of the durable record: metadata, digests, and the class and code of a failure, never content.
    class RecordReader
      CONTRACT_VERSION = 2
      DEFAULT_LIMIT = 20_000
      IDENTIFIER = /\A[A-Za-z0-9_:.-]{1,128}\z/

      Query = Data.define(:columns, :from, :thread_column, :order, :failure_column)

      QUERIES = {
        requests: Query.new(
          columns: %w[thread_id request_id operation status execution_id input_digest payload_digest
                      response_digest terminal_error_digest retryable created_at_ms updated_at_ms],
          from: 'tamoz_requests', thread_column: 'thread_id', order: 'updated_at_ms',
          failure_column: 'terminal_error'
        ),
        effects: Query.new(
          columns: %w[effect_key thread_id execution_id task_id request_id call_index operation safety
                      status requires_reconciliation current_attempt request_digest created_at_ms
                      updated_at_ms],
          from: 'tamoz_effects', thread_column: 'thread_id', order: 'updated_at_ms', failure_column: nil
        ),
        effect_attempts: Query.new(
          columns: %w[a.effect_key a.attempt_number a.status a.deadline_ms a.result_digest a.error_digest
                      a.prepared_at_ms a.started_at_ms a.completed_at_ms],
          from: 'tamoz_effect_attempts a JOIN tamoz_effects e ON e.effect_key = a.effect_key',
          thread_column: 'e.thread_id', order: 'a.prepared_at_ms', failure_column: 'a.error'
        ),
        checkpoints: Query.new(
          columns: %w[id thread_id execution_id sequence status graph_name graph_version payload_digest
                      created_at_ms],
          from: 'tamoz_checkpoints', thread_column: 'thread_id', order: 'created_at_ms', failure_column: nil
        ),
        approval_decisions: Query.new(
          columns: %w[decision_id session_id tool verb tier rule_id verdict policy_rev argv_digest
                      targets_digest answer resolved_scope actor_evidence resolved_at_ms created_at_ms],
          from: 'tamoz_approval_decisions', thread_column: nil, order: 'created_at_ms', failure_column: nil
        ),
        occurrences: Query.new(
          columns: %w[occurrence_id schedule_id request_id state nominal_fire_at_utc created_at_ms
                      updated_at_ms],
          from: 'tamoz_occurrences', thread_column: nil, order: 'updated_at_ms', failure_column: nil
        )
      }.freeze

      attr_reader :path

      def self.open(path:)
        database_file = DatabaseFile.new(path:)
        raise ConfigurationError, "no Tamoz database at #{database_file.path}" unless File.file?(database_file.path)

        database_file.verify!(repair_permissions: false)
        new(database_file.path, read_only_connection(database_file.path))
      end

      def self.read_only_connection(path)
        connection = ::SQLite3::Database.new(path, readonly: true, strict: true, results_as_hash: false)
        connection.execute('PRAGMA query_only = ON')
        Migrator.verify_connection!(connection)
        connection.execute('BEGIN')
        connection
      rescue ::SQLite3::Exception => e
        connection&.close
        ExceptionMapper.raise_mapped(e, operation: 'record_reader.open')
      rescue StandardError
        connection&.close
        raise
      end
      private_class_method :read_only_connection

      def initialize(path, connection)
        @path = path
        @connection = connection
        @codec = StateCodec.new
      end

      def requests(thread: nil, limit: DEFAULT_LIMIT) = rows(:requests, thread:, limit:)
      def effects(thread: nil, limit: DEFAULT_LIMIT) = rows(:effects, thread:, limit:)
      def effect_attempts(thread: nil, limit: DEFAULT_LIMIT) = rows(:effect_attempts, thread:, limit:)
      def checkpoints(thread: nil, limit: DEFAULT_LIMIT) = rows(:checkpoints, thread:, limit:)
      def approval_decisions(thread: nil, limit: DEFAULT_LIMIT) = rows(:approval_decisions, thread:, limit:)
      def occurrences(thread: nil, limit: DEFAULT_LIMIT) = rows(:occurrences, thread:, limit:)

      def close
        @connection.close unless @connection.closed?
      end

      private

      def rows(kind, thread:, limit:)
        query = QUERIES.fetch(kind)
        @connection.execute(sql(query, thread), binds(thread, limit)).map { |row| record(query, row) }.freeze
      rescue ::SQLite3::Exception => e
        ExceptionMapper.raise_mapped(e, operation: "record_reader.#{kind}")
      end

      def sql(query, thread)
        raise ConfigurationError, "#{query.from} has no thread column" if thread && !query.thread_column

        columns = query.columns + [query.failure_column].compact
        filter = thread && query.thread_column ? " WHERE #{query.thread_column} = ?" : ''
        "SELECT #{columns.join(', ')} FROM #{query.from}#{filter} ORDER BY #{query.order} DESC LIMIT ?"
      end

      def binds(thread, limit)
        bounded = Integer(limit)
        raise ConfigurationError, 'limit must be positive' unless bounded.positive?

        thread ? [thread, bounded] : [bounded]
      end

      def record(query, row)
        names = query.columns.map { |column| column.split('.').last }
        values = names.zip(row).to_h
        values['failure'] = failure(row.last) if query.failure_column
        Tamoz::Core.deep_freeze(values)
      end

      def failure(bytes)
        return nil unless bytes

        value = @codec.load(bytes.b)
        return nil if value.nil?

        value.is_a?(Hash) ? failure_summary(value) : { 'class' => 'unclassified' }
      rescue StandardError
        { 'class' => 'undecodable' }
      end

      def failure_summary(value)
        { 'class' => identifier(value['class']) || 'unclassified', 'code' => identifier(value['code']) }.compact
      end

      def identifier(value)
        text = value.to_s
        text.match?(IDENTIFIER) && !Tamoz::Core.secret_shaped?(text) ? text : nil
      end
    end
  end
end
