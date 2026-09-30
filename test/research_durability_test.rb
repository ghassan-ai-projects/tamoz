# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require 'timeout'
require_relative 'test_helper'
require_relative 'support/research_spec'

# Quality-bar rows P4 and C7 of docs/deep-research-2026-09-30: a real SIGKILL lands inside a deep-research turn on the
# SQLite store and the turn is recovered in a new process. An in-process exception would release the lease in `ensure`
# and hide the risk these rows exist to catch.
class ResearchDurabilityTest < Minitest::Test
  include ResearchSpec

  # The child drives the real research turn over the shared store and the fixture web:
  # `plan` pauses at the checkpoint and is killed there (the pause is already durable);
  # `wave` accepts the plan and is killed with the wave in flight.
  CHILD_SCRIPT = <<~RUBY
    require 'test_helper'
    require 'support/research_spec'
    include ResearchSpec

    stage = ENV.fetch('TAMOZ_STAGE')
    lead = { calls: [plan_call] }
    adapter = Tamoz::SQLite::Adapter.new(path: ENV.fetch('TAMOZ_DB'),
                                         limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.4, effect_attempt_ttl: 0.4))
    model = ScriptedTeam.new(parent: [lead, { content: 'Waiting.' }], child: happy_children)
    session = research_session(model:, root: ENV.fetch('TAMOZ_ROOT'), adapter:, web: FixtureWebsearch.new,
                               out: ENV.fetch('TAMOZ_OUT'))
    session.research(QUESTION, thread: 'research', request_id: 'r1')
    if stage == 'plan'
      # The turn is paused and the pause is durable; the kill leaves it that way.
      kill_here.call(nil)
    else
      # The wave runs on the answer's own request, so the kill is scripted for that request alone.
      answered = research_session(model: ScriptedTeam.new(parent: [kill_here], child: happy_children),
                                  root: ENV.fetch('TAMOZ_ROOT'), adapter:, web: FixtureWebsearch.new,
                                  out: ENV.fetch('TAMOZ_OUT'))
      answer_plan(answered, 'go', request_id: 'wave-after-answer')
    end
  RUBY

  # P4: the pause survives the kill, and the answer given after the restart resumes the same turn rather than asking
  # for the plan a second time.
  def test_p4_a_killed_checkpoint_resumes_the_same_turn_after_a_restart
    with_killed_research(stage: 'plan') do |root, adapter, out, _directory|
      session = recovered(root, adapter, out)
      paused = session.view(thread: 'research').interrupts

      assert_equal 1, paused.length, 'the pause did not survive the kill'

      outcome = answer_plan(session, 'go', request_id: 'answer-after-kill')

      assert_equal :completed, outcome.status, outcome.inspect[0, 800]
      assert_equal 'reported', session.view(thread: 'research').state.fetch(:terminal_reason)
      # The same plan was carried, not re-derived: the run finished without asking for the plan again.
      assert_empty session.view(thread: 'research').interrupts
      assert_equal 0, run_record(out).fetch('plan_edits'), 'the plan was asked for again after the restart'
      assert_includes File.read(Dir[File.join(out, '*', 'report.md')].first), '717,710'
    end
  end

  # C7: a kill with a wave in flight. The resumed run repeats no recorded search, page read or model call.
  def test_c7_a_kill_mid_wave_repeats_no_recorded_search_page_read_or_model_call
    with_killed_research(stage: 'wave') do |root, adapter, out, _directory|
      before = journal(adapter)
      session = recovered(root, adapter, out)
      # The wave runs on the answer's request; that is the request the kill left running.
      outcome = recover_research(session, request_id: 'wave-after-answer')

      assert_equal :completed, outcome.status, outcome.inspect[0, 800]
      refute_empty Dir[File.join(out, '*', 'report.md')]
      assert_operator run_record(out).fetch('sources'), :>=, 1
      # Searches, page reads and model calls are all durable effects; the crash left exactly one of them in flight.
      after = journal(adapter)
      resolved = before.zip(after).count do |was, now|
        now && was[:status] != 'succeeded' && now[:status] == 'succeeded'
      end

      assert_operator resolved, :<=, 1, "more than the one in-flight call was re-run: #{after.inspect}"
      assert_no_call_reissued(before, after)
      assert_equal before.map { |row| row.slice(:operation, :execution_id) },
                   after.first(before.length).map { |row| row.slice(:operation, :execution_id) },
                   'the resumed run ran a different sequence of work than the crashed run'
    end
  end

  # The carry is scoped to a turn that had not finished. Every way a research turn ends leaves it terminal, so a
  # finished run must not hand its accepted plan to the next question on the thread — that would answer a different
  # question under the old brief, and count the old run's searches against the new one's budget.
  def test_a_new_question_on_a_finished_thread_opens_its_own_plan
    { 'reported' => happy_lead, 'cancelled_by_user' => [{ calls: [plan_call] }] }.each do |ending, lead|
      assert_next_question_is_fresh(ending, lead)
    end
  end

  private

  def assert_next_question_is_fresh(ending, lead)
    with_fixture_web do
      with_work_workspace do |root, adapter|
        Dir.mktmpdir('tamoz-research-next') do |out|
          finish_a_run(root, adapter, out, lead, ending)

          fresh = ScriptedTeam.new(parent: [{ calls: [plan_call] }, { content: 'Waiting.' }], child: [])
          nxt = research_session(model: fresh, root:, adapter:, web: FixtureWebsearch.new, out:)
          outcome = nxt.research('What is the capital of Peru?', thread: 'research', request_id: 'r2')
          state = nxt.view(thread: 'research').state[:research]

          assert_equal :paused, outcome.status, "the #{ending} run handed its accepted plan to the next question"
          refute state['accepted'], "the next question inherited the #{ending} run's acceptance"
          assert_nil state['brief'], "the next question inherited the #{ending} run's brief"
          assert_empty state['children'], "the next question inherited the #{ending} run's children"
          assert_equal 1, nxt.view(thread: 'research').interrupts.length
        end
      end
    end
  end

  def finish_a_run(root, adapter, out, lead, ending)
    first = research_session(model: ScriptedTeam.new(parent: lead, child: happy_children),
                             root:, adapter:, web: FixtureWebsearch.new, out:)
    start_research(first)
    reply(first, ending == 'reported' ? 'go' : 'stop')

    assert_equal ending, first.view(thread: 'research').state.fetch(:terminal_reason)
  end

  def with_killed_research(stage:, &)
    with_fixture_web do
      Dir.mktmpdir('tamoz-research-durability') do |directory|
        root = File.join(directory, 'workspace')
        FileUtils.mkdir_p(root)
        out = File.join(directory, 'out')
        FileUtils.mkdir_p(out)
        database = File.join(directory, 'tamoz.sqlite3')
        spawn_killed(directory, root, out, database, stage:)
        expire_leases(database)
        yield root, adapter_at(database, 5.0), out, directory
      end
    end
  end

  def spawn_killed(directory, root, out, database, stage:)
    env = { 'TAMOZ_DB' => database, 'TAMOZ_ROOT' => File.realpath(root), 'TAMOZ_OUT' => out,
            'TAMOZ_STAGE' => stage, 'RUBYOPT' => nil, 'BUNDLER_SETUP' => nil }
    errors = File.join(directory, 'child.err')
    pid = Process.spawn(env, RbConfig.ruby, *SUBPROCESS_LIB_ARGS, '-e', CHILD_SCRIPT, out: File::NULL, err: errors)
    status = Timeout.timeout(120) { Process.wait2(pid).last }

    assert_equal 9, status.termsig, "the process was meant to die of SIGKILL: #{File.read(errors)}"
  end

  # The crashed owner's lease is expired by hand: deterministic, and it pays no real time (testing.md).
  def expire_leases(database)
    SQLite3::Database.open(database) do |db|
      db.execute('UPDATE tamoz_namespaces SET lease_expires_at_ms = 0 WHERE lease_owner_id IS NOT NULL')
    end
  end

  def adapter_at(database, ttl)
    Tamoz::SQLite::Adapter.new(path: database,
                               limits: Tamoz::SQLite::Limits.new(lease_ttl: ttl, effect_attempt_ttl: ttl))
  end

  def recovered(root, adapter, out)
    research_session(model: ScriptedTeam.new(parent: happy_lead, child: happy_children),
                     root:, adapter:, web: FixtureWebsearch.new, out:)
  end

  def run_record(out) = JSON.parse(File.read(Dir[File.join(out, '*', 'run.json')].first))

  # The journal rows for one class of call, in the order they were recorded.
  def recorded(rows, kind)
    rows.select { |row| row[:operation].to_s.include?(kind) }
  end

  # No search, page read or model call gained a receipt the crashed run had not already recorded for that same call.
  def assert_no_call_reissued(before, after)
    %w[search read_page model].each do |kind|
      assert_equal recorded(before, kind).map { |row| row[:execution_id] },
                   recorded(after, kind).first(recorded(before, kind).length).map { |row| row[:execution_id] },
                   "the resumed run re-issued a recorded #{kind} call"
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
