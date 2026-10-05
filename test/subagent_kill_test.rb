# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require 'timeout'
require_relative 'test_helper'
require_relative 'support/subagent_spec'

# Quality-bar row C1: a real SIGKILL, delivered to a real process, lands in the middle of a subagent run on the SQLite
# store. An in-process exception would release the child namespace's lease in `ensure` and hide the lease risk this row
# exists to catch.
class SubagentKillTest < Minitest::Test
  include SubagentSpec

  CHILD_SCRIPT = <<~RUBY
    require 'tamoz/sqlite'
    require 'tamoz/agent'
    require 'support/subagent_fixtures'
    include SubagentFixtures

    ttl = Float(ENV.fetch('TAMOZ_TTL'))
    adapter = Tamoz::SQLite::Adapter.new(path: ENV.fetch('TAMOZ_DB'),
                                         limits: Tamoz::SQLite::Limits.new(lease_ttl: ttl, effect_attempt_ttl: ttl))
    die = lambda do |_|
      Process.kill('KILL', Process.pid)
      sleep 5
    end
    child = [{ calls: [read_call('lib/a.rb')] }, { calls: [read_call('lib/b.rb')] }, { content: 'a and b are constants.' }]
    child[Integer(ENV.fetch('TAMOZ_KILL_AT_CALL')) - 1] = die
    model = ScriptedTeam.new(parent: delegate_once, child:)
    subagent_session(model:, root: ENV.fetch('TAMOZ_ROOT'), adapter:).start(TASK, thread: 'work', request_id: 'work-1')
  RUBY

  CHILD_TURNS = [{ calls: [['read_file', { 'path' => 'lib/a.rb' }]] },
                 { calls: [['read_file', { 'path' => 'lib/b.rb' }]] },
                 { content: 'a and b are constants.' }].freeze

  def wait_for(pid)
    Timeout.timeout(120) { Process.wait2(pid).last }
  rescue Timeout::Error
    Process.kill('KILL', pid)
    raise
  end

  def workspace_at(directory)
    root = File.join(directory, 'workspace')
    EXPLORE_FILES.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
    root
  end

  def with_killed_process(model_calls)
    Dir.mktmpdir('tamoz-subagent-kill') do |directory|
      root = workspace_at(directory)
      env = { 'TAMOZ_DB' => File.join(directory, 'tamoz.sqlite3'), 'TAMOZ_ROOT' => File.realpath(root),
              'TAMOZ_TTL' => '0.4', 'TAMOZ_KILL_AT_CALL' => (model_calls + 1).to_s, 'RUBYOPT' => nil,
              'BUNDLER_SETUP' => nil }
      errors = File.join(directory, 'child.err')
      pid = Process.spawn(env, RbConfig.ruby, *SUBPROCESS_LIB_ARGS, '-e', CHILD_SCRIPT, out: File::NULL, err: errors)
      status = wait_for(pid)

      assert_equal 9, status.termsig, "the process was meant to die of SIGKILL: #{File.read(errors)}"
      SQLite3::Database.open(env.fetch('TAMOZ_DB')) do |database|
        database.execute('UPDATE tamoz_namespaces SET lease_expires_at_ms = 0 WHERE lease_owner_id IS NOT NULL')
      end
      adapter = Tamoz::SQLite::Adapter.new(path: env.fetch('TAMOZ_DB'),
                                           limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 5.0))
      yield File.realpath(root), adapter
    ensure
      adapter&.close
    end
  end

  def test_a_killed_process_leaves_a_child_that_resumes_and_replays_its_recorded_calls
    spec_row('C1') do
      [1, 2].each do |recorded|
        with_killed_process(recorded) do |root, adapter|
          parent = [{ content: 'Totals round in two places.' }]
          model = SubagentFixtures::ScriptedTeam.new(parent:, child: CHILD_TURNS.drop(recorded))
          outcome = subagent_session(model:, root:, adapter:).recover(thread: 'work', request_id: 'work-1')

          assert_equal [:completed, 'answered'], [outcome.status, outcome.state.fetch(:terminal_reason)]
          assert_equal 3 - recorded, model.child_requests.length, 'a recorded child call reached the provider again'
          assert_equal 1, model.parent_requests.length
          assert_equal uncrashed_result(root, CHILD_TURNS), delegation_results(model).first
        end
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
