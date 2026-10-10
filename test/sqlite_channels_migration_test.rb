# frozen_string_literal: true

require_relative 'test_helper'
require 'sqlite3'
require 'tmpdir'

# Migration 26 recreates every comms table empty in the new shape and leaves every other table as it was.
class SQLiteChannelsMigrationTest < Minitest::Test
  Migrator = Tamoz::SQLite::Migrator

  def schema_at(path, version)
    database = SQLite3::Database.new(path)
    (1..version).each do |ordinal|
      statements, checksum = Migrator.const_get(:MIGRATIONS).fetch(ordinal)
      statements.each { |sql| database.execute_batch(sql) }
      database.execute('INSERT INTO tamoz_schema_migrations(version, checksum, applied_at_ms) VALUES (?, ?, 0)',
                       [ordinal, checksum])
    end
    database.execute('PRAGMA application_id = 1413565786')
    database.execute("PRAGMA user_version = #{version}")
    database
  end

  def others(database)
    database.execute("SELECT name, sql FROM sqlite_master WHERE tbl_name NOT LIKE 'tamoz_comms%' ORDER BY name")
  end

  def decision(database, id, actor_kind, source)
    database.execute(<<~SQL)
      INSERT INTO tamoz_comms_decisions VALUES ('#{id}', 't', 'o', '#{'b' * 64}', 'deny', '#{actor_kind}', 'a',
        '#{source}', 1, 2, 'pending', NULL, NULL, NULL, NULL, NULL, NULL)
    SQL
  end

  def test_an_upgrade_from_25_empties_the_comms_tables_and_keeps_everything_else
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      database = schema_at(path, 25)
      decision(database, 'd1', 'os_user', 'cli')
      database.execute("INSERT INTO tamoz_threads (thread_id, created_at_ms, updated_at_ms) VALUES ('kept', 1, 2)")
      database.execute('INSERT INTO tamoz_comms_poll_state (bot_id, surface_id, next_offset, updated_at_ms) ' \
                       "VALUES (7, 'telegram', 42, 1)")
      before = others(database)
      database.close
      File.chmod(0o600, path)

      Tamoz::SQLite::Adapter.new(path:).close
      database = SQLite3::Database.new(path)

      assert_equal 26, database.get_first_value('PRAGMA user_version')
      assert_equal 0, database.get_first_value('SELECT count(*) FROM tamoz_comms_decisions')
      assert_equal 0, database.get_first_value('SELECT count(*) FROM tamoz_comms_poll_state')
      assert_equal before, others(database)
      assert_equal [['kept', nil, 1, 2]], database.execute('SELECT * FROM tamoz_threads')
    ensure
      database&.close
    end
  end

  def test_a_decision_names_one_kind_on_both_sides
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      Tamoz::SQLite::Adapter.new(path:).close
      database = SQLite3::Database.new(path)

      decision(database, 'd1', 'os_user', 'cli')
      decision(database, 'd2', 'loopback_user', 'loopback')

      [%w[x1 telegram_user talk], %w[x2 os_user telegram], %w[x3 cli_user cli], %w[x4 Slack_user Slack]]
        .each do |id, actor_kind, source|
          assert_raises(SQLite3::ConstraintException, id) { decision(database, id, actor_kind, source) }
        end
    ensure
      database&.close
    end
  end
end
