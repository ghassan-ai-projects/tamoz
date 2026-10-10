# frozen_string_literal: true

require_relative "test_helper"

class SQLiteKernelTest < Minitest::Test
  def test_creates_secure_migrated_database_and_closes_every_connection
    Dir.mktmpdir("tamoz-sqlite") do |directory|
      path = File.join(directory, "tamoz.db")
      adapter = Tamoz::SQLite::Adapter.new(path:)

      assert_equal 0, File.stat(path).mode & 0o077
      assert_equal(
        {
          "integrity" => ["ok"],
          "foreign_key_violations" => [],
          "schema_version" => Tamoz::SQLite::Migrator::CURRENT_VERSION,
          "ok" => true
        },
        adapter.integrity_check
      )
      assert_equal 4, adapter.stats.fetch("available")
      assert adapter.close
      refute adapter.close
      assert adapter.closed?
    end
  end

  def test_failed_transaction_maps_the_sqlite_cause_and_rolls_back_schema_changes
    Dir.mktmpdir('tamoz-sqlite-failed-transaction') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'tamoz.db'))
      error = assert_raises(Tamoz::SQLite::Error) do
        adapter.__send__(:transaction, operation: 'test.failed_write') do |transaction|
          transaction.execute('test.create', 'CREATE TABLE rollback_probe (value TEXT)', [])
          transaction.execute('test.invalid', 'INSERT INTO absent_table VALUES (1)', [])
        end
      end

      assert_instance_of SQLite3::SQLException, error.cause
      assert_equal 'test.failed_write: SQLite failure SQLite3::SQLException', error.message
      assert_equal 4, adapter.stats.fetch('available')
      tables = adapter.__send__(:read, operation: 'test.rollback') do |transaction|
        transaction.scalar('test.tables', "SELECT COUNT(*) FROM sqlite_master WHERE name = 'rollback_probe'", [])
      end
      assert_equal 0, tables
    ensure
      adapter&.close
    end
  end

  def test_exhausted_busy_transaction_preserves_its_cause_and_returns_the_connection
    Dir.mktmpdir('tamoz-sqlite-busy-transaction') do |directory|
      fault = lambda do |point, metadata|
        if point == :before_begin && metadata.fetch('operation') == 'test.busy'
          raise SQLite3::BusyException, 'injected busy'
        end
      end
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, 'tamoz.db'), limits: Tamoz::SQLite::Limits.new(retry_limit: 0), fault_injector: fault
      )
      error = assert_raises(Tamoz::SQLite::BusyError) do
        adapter.__send__(:transaction, operation: 'test.busy') { flunk 'busy transaction reached its body' }
      end

      assert_instance_of SQLite3::BusyException, error.cause
      assert_equal 'test.busy: SQLite remained busy', error.message
      assert_equal 4, adapter.stats.fetch('available')
    ensure
      adapter&.close
    end
  end

  def test_rejects_symlink_and_unsafe_permissions_unless_repair_is_explicit
    Dir.mktmpdir("tamoz-sqlite-permissions") do |directory|
      target = File.join(directory, "target.db")
      File.write(target, "")
      File.chmod(0o644, target)

      assert_raises(Tamoz::SQLite::PermissionError) do
        Tamoz::SQLite::Adapter.new(path: target)
      end

      repaired = Tamoz::SQLite::Adapter.new(
        path: target,
        repair_permissions: true
      )
      assert_equal 0, File.stat(target).mode & 0o077
      repaired.close

      link = File.join(directory, "link.db")
      File.symlink(target, link)
      assert_raises(Tamoz::SQLite::PermissionError) do
        Tamoz::SQLite::Adapter.new(path: link)
      end
    end
  end

  # There is no upgrade path: a database at any other schema version is refused by name, never layered on.
  def test_a_database_at_another_schema_version_is_refused_with_a_reset_instruction
    Dir.mktmpdir("tamoz-sqlite-older") do |directory|
      path = File.join(directory, "tamoz.db")
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA application_id = #{Tamoz::SQLite::Migrator.const_get(:APPLICATION_ID)}")
      database.execute("PRAGMA user_version = #{Tamoz::SQLite::Migrator::CURRENT_VERSION - 1}")
      database.close
      File.chmod(0o600, path)

      error = assert_raises(Tamoz::SQLite::MigrationError) { Tamoz::SQLite::Adapter.new(path:) }
      assert_includes error.message, "start a fresh one"
    end
  end

  def test_failed_migration_rolls_back_all_schema_statements
    Dir.mktmpdir("tamoz-sqlite-migration") do |directory|
      path = File.join(directory, "tamoz.db")
      injected = false
      fault = lambda do |point, metadata|
        next unless point == :after_sql
        next unless metadata.fetch("operation") == "migration.#{Tamoz::SQLite::Migrator::CURRENT_VERSION}"
        next unless metadata.fetch("statement") == "migration.#{Tamoz::SQLite::Migrator::CURRENT_VERSION}.5"

        injected = true
        raise "injected migration failure"
      end

      assert_raises(RuntimeError) do
        Tamoz::SQLite::Adapter.new(path:, fault_injector: fault)
      end
      assert injected

      database = SQLite3::Database.new(path)
      assert_equal 0, database.get_first_value("PRAGMA user_version")
      tables = database.execute(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name LIKE 'tamoz_%'"
      )
      assert_empty tables
      database.close

      recovered = Tamoz::SQLite::Adapter.new(path:)
      assert recovered.integrity_check.fetch("ok")
      recovered.close
    end
  end

  def test_migration_checksum_tampering_is_rejected
    Dir.mktmpdir("tamoz-sqlite-checksum") do |directory|
      path = File.join(directory, "tamoz.db")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      adapter.close

      database = SQLite3::Database.new(path)
      database.execute(
        "UPDATE tamoz_schema_migrations SET checksum = ? WHERE version = ?",
        ["tampered", Tamoz::SQLite::Migrator::CURRENT_VERSION]
      )
      database.close

      assert_raises(Tamoz::SQLite::MigrationError) do
        Tamoz::SQLite::Adapter.new(path:)
      end
    end
  end

  def test_connection_checkout_uses_one_bounded_deadline
    Dir.mktmpdir("tamoz-sqlite-pool") do |directory|
      limits = Tamoz::SQLite::Limits.new(
        pool_size: 1,
        checkout_timeout: 0.01,
        operation_timeout: 0.02,
        busy_timeout: 0.005
      )
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        limits:
      )

      adapter.pool.with_connection do
        assert_raises(Tamoz::SQLite::BusyError) do
          adapter.pool.with_connection { flunk "second connection was created" }
        end
      end
      assert_equal(
        {"size" => 1, "available" => 1, "checked_out" => 0, "closed" => false},
        adapter.pool.stats
      )
      adapter.close
    end
  end

  def test_adapter_fails_closed_when_inherited_across_fork
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    Dir.mktmpdir("tamoz-sqlite-fork") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      reader, writer = IO.pipe
      child = fork do
        reader.close
        begin
          adapter.stats
          writer.write("unexpected")
        rescue Tamoz::SQLite::ClosedError
          writer.write("closed")
        ensure
          writer.close
        end
        exit! 0
      end
      writer.close
      assert_equal "closed", reader.read
      Process.wait(child)
      reader.close
      assert adapter.integrity_check.fetch("ok")
      adapter.close
    end
  end
end
