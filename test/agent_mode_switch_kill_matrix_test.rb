# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require 'delegate'
require 'sqlite3'

# Step 7B kill matrix (ADR §2.6): the mid-session switch deliberately breaks
# in-flight rev stability, so its failure modes are pinned here. Hard zeros:
# MS-4 (applied exactly once across restart; an in-flight step is never
# re-decided) and MS-5 (never leaks to another session).
class AgentModeSwitchKillMatrixTest < Minitest::Test
  include AutonomyCase

  # Dies the way `kill -9` would — outside StandardError, so every rescue
  # between here and the process boundary is walked through, not around.
  class Killed < Exception; end # rubocop:disable Lint/InheritException

  def test_a_switch_across_restart_is_applied_exactly_once
    with_runtime do |rt|
      set_approval_profile(rt, 'review')
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})

      first_runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { edit_model },
        lease_ttl: 0.2
      )
      first_runtime.checkpoints.enqueue_request(
        thread_id: 't1', request_id: 'sw-req', operation: :mode_switch,
        payload: {'mode' => 'auto'}, delivery: :queue
      )
      crash_after_record(first_runtime)
      first_worker = Tamoz::Agent::Worker.new(
        runtime: first_runtime,
        session_builder: ->(thread_id) { first_runtime.session_for(thread_id) },
        emitter: ->(_event) {}, once: true
      )

      assert_raises(Killed) { first_worker.poll_once }
      first_runtime.close

      sleep 0.25
      second_runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { edit_model },
        lease_ttl: 0.2
      )
      second_worker = Tamoz::Agent::Worker.new(
        runtime: second_runtime,
        session_builder: ->(thread_id) { second_runtime.session_for(thread_id) },
        emitter: ->(_event) {}, once: true
      )
      second_worker.poll_once

      assert_equal 1, switch_count(rt), 'the replay must dedupe on the switch id'
      request = second_runtime.checkpoints.fetch_request(thread_id: 't1', request_id: 'sw-req')
      assert request.terminal?, 'the consumed switch must be terminal'
      revs = second_runtime.approval_engine.instance_variable_get(:@session_revs)
      assert_equal auto_rev, revs.fetch('profile:default')

      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      second_runtime.checkpoints.enqueue_request(
        thread_id: 't1', request_id: 'turn-after', operation: :turn,
        payload: {'task' => 'Fix note.txt'}, delivery: :queue
      )
      second_worker.poll_once

      view = second_runtime.session_for('t1').view(thread: 't1')
      assert_equal :completed, view.status, 'the post-switch turn must auto-allow the edit'
      assert_empty rt_pending(rt)
      assert_equal 1, switch_count(rt)
    end
  end

  def test_a_switch_between_decision_and_dispatch_never_redecides_the_in_flight_step
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      set_approval_profile(rt, 'review')
      rt.cli(['queue', 'add', '--task', 'Fix note.txt', '--profile', 'trusted', '--thread', 't1'],
             factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)

      pending = rt.pending_approvals
      assert_equal 1, pending.length
      rt.cli(["approve", pending.first.fetch('request_id'), '--json'])
      rt.cli(%w[approve --mode plan --thread t1 --json])
      rt.cli(%w[worker --once --json], factory: edit_factory)

      assert_equal "fixed\n", File.read(File.join(rt.workspace, 'note.txt')),
                   'the approved step must execute exactly once, against its issuing decision'
      approved_index = rt.events.index { |event| event['event'] == 'request.approved' }
      switched_index = rt.events.index { |event| event['event'] == 'request.mode_switched' }
      refute_nil approved_index
      refute_nil switched_index
      # Order within one pass is free: decision reuse makes the issuing
      # decision own the step whichever lands first.
      assert_equal 1, switch_count(rt)
      assert_hard_counters_zero(rt)
    end
  end

  private

  # Wraps only rebind_session: the real rebind lands (and is audited), then
  # the process dies before the request can be consumed.
  def crash_after_record(runtime)
    proxy = SimpleDelegator.new(runtime.approval_engine)
    def proxy.rebind_session(**arguments)
      super
      raise Killed, 'simulated kill -9 after the switch was applied'
    end
    runtime.instance_variable_set(:@approval_engine, proxy)
  end

  def rt_pending(rt)
    rt.status_document.fetch('paused_approvals', [])
  end

  def edit_model
    ScriptedModel.new(
      plan: [plan_step('read_file', {'path' => 'note.txt'}), edit_plan],
      review: [accepted_review],
      verify: [{'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt']}]
    )
  end

  def set_approval_profile(rt, name)
    path = File.join(rt.dir, 'config.yaml')
    document = Psych.load_file(path)
    document['approval'] = {'profile' => name}
    File.write(path, Psych.dump(document))
  end

  def bundled_profile_rev(name)
    Tamoz::Approval::PolicyDocument.load_profile(
      Tamoz::Approval.bundled_policy_path, name,
      evidence_symbols: Tamoz::Comms::AuthorityEvidence.members
    ).policy_rev
  end

  def review_rev = bundled_profile_rev('review')

  def auto_rev = bundled_profile_rev('auto')

  def switch_count(rt)
    database = SQLite3::Database.new(File.join(rt.dir, 'runtime.sqlite3'), readonly: true)
    count = database.get_first_value('SELECT COUNT(*) FROM tamoz_approval_mode_switches')
    database.close
    count
  end
end
