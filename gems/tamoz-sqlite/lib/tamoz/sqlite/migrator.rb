# frozen_string_literal: true

require "digest"

module Tamoz
  module SQLite
    class Migrator
      APPLICATION_ID = 0x54414D5A # TAMZ
      CURRENT_VERSION = 1

      MIGRATION_1 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_schema_migrations (
            version INTEGER PRIMARY KEY,
            checksum TEXT NOT NULL,
            applied_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_threads (
            thread_id TEXT PRIMARY KEY,
            tombstone_id TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_namespaces (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            active_checkpoint_id TEXT,
            next_checkpoint_sequence INTEGER NOT NULL DEFAULT 0
              CHECK (next_checkpoint_sequence >= 0),
            next_request_sequence INTEGER NOT NULL DEFAULT 0
              CHECK (next_request_sequence >= 0),
            lease_owner_id TEXT,
            lease_fence INTEGER NOT NULL DEFAULT 0 CHECK (lease_fence >= 0),
            lease_expires_at_ms INTEGER,
            greatest_backend_time_ms INTEGER NOT NULL DEFAULT 0
              CHECK (greatest_backend_time_ms >= 0),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace),
            FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_checkpoints (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence >= 0),
            parent_id TEXT,
            format_version INTEGER NOT NULL CHECK (format_version > 0),
            graph_name TEXT NOT NULL,
            graph_version TEXT NOT NULL,
            digest_version INTEGER NOT NULL CHECK (digest_version > 0),
            definition_digest TEXT NOT NULL,
            fence INTEGER NOT NULL CHECK (fence > 0),
            status TEXT NOT NULL CHECK (
              status IN ('running', 'paused', 'failed', 'completed')
            ),
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            UNIQUE (thread_id, namespace, sequence),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (parent_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_checkpoint_history
            ON tamoz_checkpoints(thread_id, namespace, sequence DESC)
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_checkpoint_execution
            ON tamoz_checkpoints(thread_id, namespace, execution_id, sequence DESC)
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_pending_activations (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            base_checkpoint_id TEXT NOT NULL,
            node TEXT NOT NULL,
            path BLOB NOT NULL,
            outcome_digest TEXT NOT NULL,
            consumed_by TEXT,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace, execution_id, task_id),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (base_checkpoint_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
            FOREIGN KEY (consumed_by) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_pending_writes (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            write_index INTEGER NOT NULL CHECK (write_index >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('channel', 'routes')),
            channel TEXT,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            PRIMARY KEY (
              thread_id, namespace, execution_id, task_id, write_index
            ),
            FOREIGN KEY (thread_id, namespace, execution_id, task_id)
              REFERENCES tamoz_pending_activations(
                thread_id, namespace, execution_id, task_id
              )
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_requests (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            request_id TEXT NOT NULL,
            enqueue_sequence INTEGER NOT NULL CHECK (enqueue_sequence >= 0),
            input_digest TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (
              operation IN ('turn', 'resume', 'retry', 'continue', 'fork', 'redirect')
            ),
            delivery_mode TEXT NOT NULL CHECK (
              delivery_mode IN ('queue', 'redirect')
            ),
            status TEXT NOT NULL CHECK (
              status IN (
                'queued', 'claimed', 'running', 'redirecting', 'completed', 'failed'
              )
            ),
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            execution_id TEXT,
            target_execution_id TEXT,
            cancellation_generation INTEGER,
            owner_fence INTEGER,
            checkpoint_id TEXT,
            response BLOB,
            response_digest TEXT,
            terminal_error BLOB,
            terminal_error_digest TEXT,
            retryable INTEGER CHECK (retryable IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace, request_id),
            UNIQUE (thread_id, namespace, enqueue_sequence),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (checkpoint_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_request_queue
            ON tamoz_requests(thread_id, namespace, enqueue_sequence)
            WHERE status NOT IN ('completed', 'failed')
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_request_transitions (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            request_id TEXT NOT NULL,
            transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
            from_status TEXT,
            to_status TEXT NOT NULL,
            fence INTEGER,
            evidence BLOB,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (
              thread_id, namespace, request_id, transition_index
            ),
            FOREIGN KEY (thread_id, namespace, request_id)
              REFERENCES tamoz_requests(thread_id, namespace, request_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effects (
            effect_key TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            call_index INTEGER NOT NULL CHECK (call_index >= 0),
            operation TEXT NOT NULL,
            safety TEXT NOT NULL CHECK (
              safety IN (
                'read_only', 'idempotent', 'transactional', 'reconcilable', 'unsafe'
              )
            ),
            request_digest TEXT NOT NULL,
            status TEXT NOT NULL CHECK (
              status IN (
                'prepared', 'running', 'succeeded', 'failed', 'unknown',
                'reconcile', 'abandoned'
              )
            ),
            current_attempt INTEGER CHECK (current_attempt > 0),
            requires_reconciliation INTEGER NOT NULL DEFAULT 0
              CHECK (requires_reconciliation IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_effect_execution
            ON tamoz_effects(thread_id, namespace, execution_id)
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effect_attempts (
            effect_key TEXT NOT NULL,
            attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
            attempt_token TEXT NOT NULL UNIQUE,
            fence INTEGER NOT NULL CHECK (fence > 0),
            status TEXT NOT NULL CHECK (
              status IN (
                'prepared', 'running', 'succeeded', 'failed', 'unknown', 'abandoned'
              )
            ),
            deadline_ms INTEGER NOT NULL,
            result BLOB,
            result_digest TEXT,
            external_id TEXT,
            error BLOB,
            error_digest TEXT,
            prepared_at_ms INTEGER NOT NULL,
            started_at_ms INTEGER,
            completed_at_ms INTEGER,
            PRIMARY KEY (effect_key, attempt_number),
            FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effect_transitions (
            effect_key TEXT NOT NULL,
            transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
            transition TEXT NOT NULL,
            attempt_number INTEGER,
            actor TEXT,
            evidence BLOB,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (effect_key, transition_index),
            FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_store_heads (
            namespace TEXT NOT NULL,
            key TEXT NOT NULL,
            current_version INTEGER NOT NULL CHECK (current_version > 0),
            deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
            sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (namespace, key)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_store_versions (
            namespace TEXT NOT NULL,
            key TEXT NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
            sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
            format_version INTEGER NOT NULL CHECK (format_version > 0),
            payload BLOB,
            payload_digest TEXT,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (namespace, key, version)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_thread_tombstones (
            thread_id TEXT PRIMARY KEY,
            tombstone_id TEXT NOT NULL UNIQUE,
            expected_tips BLOB NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active', 'purged')),
            effect_policy TEXT NOT NULL,
            authorization BLOB NOT NULL,
            report BLOB NOT NULL,
            report_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            purge_after_ms INTEGER,
            FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_deletion_receipts (
            tombstone_id TEXT PRIMARY KEY,
            thread_id_digest TEXT NOT NULL,
            report BLOB NOT NULL,
            report_digest TEXT NOT NULL,
            purged_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
      ].freeze

      MIGRATION_1_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_1.join("\n-- tamoz migration boundary --\n")
      ).freeze

      attr_reader :path, :limits, :fault_injector

      def self.verify_connection!(connection)
        application_id = connection.get_first_value("PRAGMA application_id")
        version = connection.get_first_value("PRAGMA user_version")
        unless application_id == APPLICATION_ID
          raise MigrationError, "SQLite application id is missing or invalid"
        end
        unless version == CURRENT_VERSION
          raise MigrationError, "SQLite schema version is invalid"
        end
        row = connection.get_first_row(
          "SELECT checksum FROM tamoz_schema_migrations WHERE version = 1"
        )
        unless row && row.fetch(0) == MIGRATION_1_CHECKSUM
          raise MigrationError, "SQLite migration 1 checksum is invalid"
        end

        version
      rescue ::SQLite3::Exception => error
        ExceptionMapper.raise_mapped(error, operation: "schema verification")
      end

      def initialize(path:, limits:, fault_injector:)
        @path = String(path).dup.freeze
        @limits = limits
        @fault_injector = fault_injector
      end

      def migrate!
        connection = ConnectionPool.open(path, limits:, initialize_wal: true)
        application_id = connection.get_first_value("PRAGMA application_id")
        version = connection.get_first_value("PRAGMA user_version")
        if application_id != 0 && application_id != APPLICATION_ID
          raise MigrationError, "SQLite application id belongs to another application"
        end
        if version > CURRENT_VERSION
          raise MigrationError,
                "SQLite schema version #{version} is newer than #{CURRENT_VERSION}"
        end

        if version.zero?
          apply_migration_1(connection)
        else
          verify_migration_1!(connection)
        end
        true
      rescue ::SQLite3::Exception => error
        ExceptionMapper.raise_mapped(error, operation: "schema migration")
      ensure
        connection&.close unless connection&.closed?
      end

      private

      def apply_migration_1(connection)
        connection.execute("BEGIN EXCLUSIVE")
        transaction = Transaction.new(
          connection:,
          operation: "migration.1",
          fault_injector:
        )
        MIGRATION_1.each_with_index do |sql, index|
          transaction.execute("migration.1.#{index + 1}", sql)
        end
        now = transaction.scalar("migration.1.time", backend_time_sql)
        transaction.execute(
          "migration.1.record",
          <<~SQL,
            INSERT INTO tamoz_schema_migrations(version, checksum, applied_at_ms)
            VALUES (?, ?, ?)
          SQL
          [1, MIGRATION_1_CHECKSUM, now]
        )
        transaction.execute(
          "migration.1.application_id",
          "PRAGMA application_id = #{APPLICATION_ID}"
        )
        transaction.execute(
          "migration.1.user_version",
          "PRAGMA user_version = #{CURRENT_VERSION}"
        )
        connection.execute("COMMIT")
      rescue Exception # rubocop:disable Lint/RescueException
        connection.execute("ROLLBACK") if connection.transaction_active?
        raise
      end

      def verify_migration_1!(connection)
        self.class.verify_connection!(connection)
      end

      def backend_time_sql
        sql = <<~SQL
          SELECT (
            CAST(strftime('%s', 'now') AS INTEGER) * 1000 +
            CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER)
          )
        SQL
        sql.lines.map(&:strip).join(" ")
      end

      private_constant :APPLICATION_ID, :CURRENT_VERSION, :MIGRATION_1,
                       :MIGRATION_1_CHECKSUM
    end
  end
end
