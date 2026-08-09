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

  # Every shipped schema version must be able to reach the current one.
  #
  # This did not hold: `migrate!` branched on `when 0` and `when 1` and let
  # everything else fall through to `verify_connection!`, which demands
  # `version == CURRENT_VERSION`. So a database created at 2, 3 or 4 raised
  # `MigrationError` on every open, forever, with no way forward.
  #
  # The database is built the way the release at that version built it: by
  # running exactly the migrator's own statements for ordinals 1..N. That is
  # why the registry is read here — a rewind (dropping rows from a current
  # database) would leave the LATER migrations' tables in place and prove
  # nothing about applying them.
  MIGRATIONS = Tamoz::SQLite::Migrator.class_eval("MIGRATIONS", __FILE__, __LINE__)
  APPLICATION_ID = Tamoz::SQLite::Migrator.class_eval("APPLICATION_ID", __FILE__, __LINE__)

  def seed_database_at_version(path, version)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA journal_mode = WAL")
    (1..version).each do |ordinal|
      statements, checksum = MIGRATIONS.fetch(ordinal)
      statements.each { |sql| database.execute(sql) }
      database.execute(
        "INSERT INTO tamoz_schema_migrations(version, checksum, applied_at_ms) VALUES (?, ?, ?)",
        [ordinal, checksum, 0]
      )
    end
    database.execute("PRAGMA application_id = #{APPLICATION_ID}")
    database.execute("PRAGMA user_version = #{version}")
    database.close
    File.chmod(0o600, path)
  end

  def test_every_shipped_schema_version_migrates_forward_in_place
    (1...Tamoz::SQLite::Migrator::CURRENT_VERSION).each do |version|
      Dir.mktmpdir("tamoz-sqlite-upgrade-#{version}") do |directory|
        path = File.join(directory, "tamoz.db")
        seed_database_at_version(path, version)

        adapter = Tamoz::SQLite::Adapter.new(path:)
        assert_equal(
          Tamoz::SQLite::Migrator::CURRENT_VERSION,
          adapter.integrity_check.fetch("schema_version"),
          "a database at version #{version} must migrate forward, not raise"
        )
        assert adapter.integrity_check.fetch("ok")
        adapter.close
      end
    end
  end

  # The upgrade path still verifies what is already there. A database claiming
  # version 3 with a tampered ordinal-2 row is not a database to layer 4 and 5
  # on top of.
  def test_an_in_place_upgrade_refuses_a_tampered_earlier_migration
    Dir.mktmpdir("tamoz-sqlite-upgrade-tampered") do |directory|
      path = File.join(directory, "tamoz.db")
      seed_database_at_version(path, 3)

      database = SQLite3::Database.new(path)
      database.execute("UPDATE tamoz_schema_migrations SET checksum = ? WHERE version = 2", ["tampered"])
      database.close

      assert_raises(Tamoz::SQLite::MigrationError) { Tamoz::SQLite::Adapter.new(path:) }
    end
  end

  def test_failed_migration_rolls_back_all_schema_statements
    Dir.mktmpdir("tamoz-sqlite-migration") do |directory|
      path = File.join(directory, "tamoz.db")
      injected = false
      fault = lambda do |point, metadata|
        next unless point == :after_sql
        next unless metadata.fetch("operation") == "migration.1"
        next unless metadata.fetch("statement") == "migration.1.5"

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
        "UPDATE tamoz_schema_migrations SET checksum = ? WHERE version = 1",
        ["tampered"]
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
