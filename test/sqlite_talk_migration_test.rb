# frozen_string_literal: true

require_relative 'test_helper'
require 'sqlite3'
require 'tmpdir'

class SQLiteTalkMigrationTest < Minitest::Test
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

  def test_an_upgrade_to_25_keeps_every_decision_and_admits_talk_actors
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      database = schema_at(path, 24)
      database.execute(<<~SQL)
        INSERT INTO tamoz_comms_decisions VALUES
          ('d1', 'tg.t.0', 'occ', '#{'b' * 64}', 'approve', 'telegram_user', 'telegram:user:1', 'telegram', 11, 22,
           'pending', NULL, NULL, NULL, NULL, 'chat_bound', 'why'),
          ('d2', 'tg.t.1', 'occ2', '#{'c' * 64}', 'deny', 'os_user', 'ops', 'cli', 33, 44,
           'claimed', 'worker:1', 7, 55, NULL, NULL, NULL),
          ('d3', 'tg.t.2', 'occ3', '#{'d' * 64}', 'approve', 'telegram_user', 'telegram:user:2', 'telegram', 66, 77,
           'consumed', 'worker:2', 9, 88, 99, 'filesystem_operator', 'tap')
      SQL
      before = database.execute('SELECT * FROM tamoz_comms_decisions ORDER BY decision_id')
      database.close
      File.chmod(0o600, path)

      Tamoz::SQLite::Adapter.new(path:).close
      database = SQLite3::Database.new(path)

      assert_equal before, database.execute('SELECT * FROM tamoz_comms_decisions ORDER BY decision_id')
      database.execute(<<~SQL)
        INSERT INTO tamoz_comms_decisions VALUES ('d4', 'tk.t.0', 'occ', '#{'b' * 64}', 'deny', 'talk_user',
          'talk:user:1', 'talk', 1, 2, 'pending', NULL, NULL, NULL, NULL, NULL, NULL)
      SQL
      assert_raises(SQLite3::ConstraintException) do
        database.execute(<<~SQL)
          INSERT INTO tamoz_comms_decisions VALUES ('d5', 't', 'o', 'x', 'deny', 'slack_user', 'x', 'slack', 1, 2,
            'pending', NULL, NULL, NULL, NULL, NULL, NULL)
        SQL
      end
      assert_equal 25, database.get_first_value('PRAGMA user_version')
    ensure
      database&.close
    end
  end
end
