# frozen_string_literal: true

require_relative 'test_helper'
require 'sqlite3'
require 'tmpdir'

# The schema binds a decision's actor and source to one channel kind.
class SQLiteChannelsMigrationTest < Minitest::Test
  def decision(database, id, actor_kind, source)
    database.execute(<<~SQL)
      INSERT INTO tamoz_comms_decisions VALUES ('#{id}', 't', 'o', '#{'b' * 64}', 'deny', '#{actor_kind}', 'a',
        '#{source}', 1, 2, 'pending', NULL, NULL, NULL, NULL, NULL, NULL)
    SQL
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
