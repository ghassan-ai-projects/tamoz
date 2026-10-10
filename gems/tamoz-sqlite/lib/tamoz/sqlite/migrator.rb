# frozen_string_literal: true

require 'digest'

module Tamoz
  module SQLite
    # Builds a fresh runtime database from the one schema migration, verifies the current one, and refuses any
    # other version.
    class Migrator
      APPLICATION_ID = 0x54414D5A # TAMZ
      # Ordinals are consumed monotonically and never reused. Without an upgrade path (ADR-059) the shipped set is
      # the one migration that builds the whole schema; a schema change replaces it with the next ordinal.
      CURRENT_VERSION = 27

      # The digest rule generation marker the schema seeds. Bumped by a
      # future forward migration whenever the canonical digest rule changes.
      DIGEST_EPOCH = 1

      MIGRATION_BOUNDARY = "\n-- tamoz migration boundary --\n"

      BACKEND_TIME_SQL =
        "SELECT ( CAST(strftime('%s', 'now') AS INTEGER) * 1000 + " \
        "CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER) )"

      SCHEMA_SQL = File.read(File.expand_path(format('../../../migrations/%04d.sql', CURRENT_VERSION), __dir__),
                             encoding: Encoding::UTF_8).freeze
      SCHEMA_STATEMENTS = SCHEMA_SQL.split(MIGRATION_BOUNDARY).map(&:freeze).freeze
      SCHEMA_CHECKSUM = Digest::SHA256.hexdigest(SCHEMA_SQL).freeze

      def self.verify_connection!(connection)
        application_id = connection.get_first_value('PRAGMA application_id')
        version = connection.get_first_value('PRAGMA user_version')
        raise MigrationError, 'SQLite application id is missing or invalid' unless application_id == APPLICATION_ID
        raise MigrationError, 'SQLite schema version is invalid' unless version == CURRENT_VERSION

        epoch = connection.get_first_value('SELECT epoch FROM tamoz_digest_epoch')
        raise MigrationError, 'SQLite digest epoch is invalid' unless epoch == DIGEST_EPOCH

        checksum = connection.get_first_value('SELECT checksum FROM tamoz_schema_migrations WHERE version = ?',
                                              [CURRENT_VERSION])
        unless checksum == SCHEMA_CHECKSUM
          raise MigrationError,
                "SQLite migration #{CURRENT_VERSION} checksum is invalid"
        end

        version
      rescue ::SQLite3::Exception => e
        ExceptionMapper.raise_mapped(e, operation: 'schema verification')
      end

      def initialize(path:, limits:, fault_injector:)
        @path = String(path).dup.freeze
        @limits = limits
        @fault_injector = fault_injector
      end

      # A fresh database is built; the current one is verified; any other is refused: there is no upgrade path
      # before 1.0 (ADR-059), so an older runtime database is moved aside and started fresh.
      def migrate!
        connection = ConnectionPool.open(@path, limits: @limits, initialize_wal: true)
        version = connection.get_first_value('PRAGMA user_version')
        refuse_foreign!(connection.get_first_value('PRAGMA application_id'), version)
        version.zero? ? build(connection) : self.class.verify_connection!(connection)
        true
      rescue ::SQLite3::Exception => e
        ExceptionMapper.raise_mapped(e, operation: 'schema migration')
      ensure
        connection&.close unless connection&.closed?
      end

      private

      def refuse_foreign!(application_id, version)
        raise MigrationError, 'SQLite application id belongs to another application' unless
          [0, APPLICATION_ID].include?(application_id)
        return if version.zero? || version == CURRENT_VERSION

        raise MigrationError, "SQLite schema version #{version} is not this Tamoz's #{CURRENT_VERSION}; " \
                              'move the runtime database aside and start a fresh one'
      end

      # The schema applies in ONE transaction, each statement under its own fault-injection label
      # (`migration.27.1`, ...), so a failure anywhere rolls every statement back.
      def build(connection)
        connection.execute('BEGIN EXCLUSIVE')
        begin
          # A process opening the same fresh database may have built it while this one waited for the lock.
          if connection.get_first_value('PRAGMA user_version') == CURRENT_VERSION
            connection.execute('COMMIT')
            return self.class.verify_connection!(connection)
          end

          transaction = apply_schema(connection)
          transaction.execute('migration.application_id', "PRAGMA application_id = #{APPLICATION_ID}")
          transaction.execute('migration.user_version', "PRAGMA user_version = #{CURRENT_VERSION}")
          connection.execute('COMMIT')
        rescue Exception # rubocop:disable Lint/RescueException
          connection.execute('ROLLBACK') if connection.transaction_active?
          raise
        end
      end

      # Every statement, then the record row. Returns the transaction so the caller stamps the PRAGMAs on it.
      def apply_schema(connection)
        label = "migration.#{CURRENT_VERSION}"
        transaction = Transaction.new(connection:, operation: label, attempt: 1, fault_injector: @fault_injector)
        SCHEMA_STATEMENTS.each_with_index { |sql, index| transaction.execute("#{label}.#{index + 1}", sql) }
        now = transaction.scalar("#{label}.time", BACKEND_TIME_SQL)
        transaction.execute("#{label}.record",
                            'INSERT INTO tamoz_schema_migrations(version, checksum, applied_at_ms) VALUES (?, ?, ?)',
                            [CURRENT_VERSION, SCHEMA_CHECKSUM, now])
        transaction
      end

      private_constant :APPLICATION_ID, :MIGRATION_BOUNDARY, :BACKEND_TIME_SQL, :SCHEMA_SQL, :SCHEMA_STATEMENTS,
                       :SCHEMA_CHECKSUM
    end
  end
end
