# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require 'sqlite3'

# Step 7B operator flow (ADR §2.6): `tamoz approve --mode NAME --thread ID`
# queues a durable control message; the worker's poll pass applies it at a
# durable boundary; the new mode governs only the next decision on THAT
# session. Every case here runs the real CLI against a real runtime directory,
# with `run_check` as the asking tool: under `review` it asks (with a grant
# offer), under `auto` it allows, under `plan` it denies.
class AgentModeSwitchTest < Minitest::Test
  include AutonomyCase

  def test_a_mode_switch_governs_the_next_turn_without_prompting
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      write_modeful_profile(rt)
      set_approval_profile(rt, 'review')

      rt.cli(['queue', 'add', '--task', 'Run the lint check', '--profile', 'modeful', '--thread', 't1'],
             factory: check_factory)
      rt.cli(%w[worker --once --json], factory: check_factory)

      pending = rt.pending_approvals
      assert_equal 1, pending.length, 'under review mode a check must ask'
      rt.cli(['approve', pending.first.fetch('request_id'), '--json'])
      rt.cli(%w[worker --once --json], factory: check_factory)
      assert_empty rt.pending_approvals

      status = rt.cli(%w[approve --mode auto --thread t1 --json])

      assert_equal 0, status, rt.err
      rt.cli(%w[worker --once --json], factory: check_factory)
      rt.cli(['queue', 'add', '--task', 'Run the lint check again', '--profile', 'modeful', '--thread', 't1'],
             factory: check_factory)
      rt.cli(%w[worker --once --json], factory: check_factory)

      assert_empty rt.pending_approvals, 'no prompt may appear after the loosened mode'
      assert_includes rt.events.map { |event| event['event'] }, 'request.mode_switched'
      rows = switch_rows(rt)
      assert_equal 1, rows.length
      assert_equal review_rev, rows.first.fetch('from_rev')
      assert_equal auto_rev, rows.first.fetch('to_rev')
      assert_hard_counters_zero(rt)
    end
  end

  def test_a_switch_never_leaks_to_another_session
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      write_modeful_profile(rt)
      set_approval_profile(rt, 'review')

      status = rt.cli(%w[approve --mode auto --thread t1 --json])

      assert_equal 0, status, rt.err
      rt.cli(['queue', 'add', '--task', 'Run the lint check', '--profile', 'modeful', '--thread', 't2'],
             factory: check_factory)
      rt.cli(%w[worker --once --json], factory: check_factory)

      pending = rt.pending_approvals
      assert_equal 1, pending.length, 'MS-5: another session keeps its own mode'
      assert_equal 't2', pending.first.fetch('thread_id')

      rows = switch_rows(rt)
      assert_equal 1, rows.length
      assert_equal 'profile:default', rows.first.fetch('session_id'),
                   'the rebind addressed only t1\'s approval session'

      asks = decision_rows_where(rt, "verdict = 'ask'")
      assert_equal ['profile:modeful'], asks.map { |row| row.fetch('session_id') }.uniq,
                   't2 asked under its own rev-bound session, untouched by the switch'
      assert_equal [review_rev], asks.map { |row| row.fetch('policy_rev') }.uniq
      assert_hard_counters_zero(rt)
    end
  end

  def test_a_parked_ask_resolves_normally_while_the_switch_waits_behind_it
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      write_modeful_profile(rt)
      set_approval_profile(rt, 'review')
      rt.cli(['queue', 'add', '--task', 'Run the lint check', '--profile', 'modeful', '--thread', 't1'],
             factory: check_factory)
      rt.cli(%w[worker --once --json], factory: check_factory)
      pending = rt.pending_approvals
      assert_equal 1, pending.length

      rt.cli(%w[approve --mode plan --thread t1 --json])

      assert_equal 1, rt.pending_approvals.length, 'the ask is still parked'
      assert_empty switch_rows(rt), 'a queued switch waits behind an open occurrence'
      assert_equal 'review', live_profile_name(rt),
                   'a queued switch changes nothing until the worker applies it'

      rt.cli(['approve', pending.first.fetch('request_id'), '--json'])
      rt.cli(%w[worker --once --json], factory: check_factory)

      assert_empty rt.pending_approvals,
                   'the parked ask resolved against its issuing decision'
      assert_equal 1, switch_rows(rt).length,
                   'the switch applied at the durable boundary after the occurrence settled'

      rt.cli(['queue', 'add', '--task', 'Run the lint check once more', '--profile', 'modeful', '--thread', 't1'],
             factory: check_factory)
      rt.cli(%w[worker --once --json], factory: check_factory)

      denies = decision_rows_where(rt, "rule_id = 'tier.local_execute' AND verdict = 'deny'")
      assert denies.any?, 'MS-6: the tightened mode denies the next check as a structured result'
      assert_empty rt.pending_approvals, 'the denial is structured; the turn continued'
      assert_hard_counters_zero(rt)
    end
  end

  def test_an_unknown_mode_fails_the_request_loudly
    with_runtime do |rt|
      status = rt.cli(%w[approve --mode nonexistent --thread t1 --json])

      assert_equal 0, status
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      row = fetch_request_row(rt)
      assert_equal 'failed', row.fetch('status'),
                   'an unloadable mode must terminally fail its request, not poison the inbox'
      assert_empty switch_rows(rt)
    end
  end

  private

  # The autonomy fixture's trusted profile plus a configured check, so
  # `run_check` exists as a dispatchable tool and can be the one that asks.
  # Local to this suite: shared support files are owned.
  def write_modeful_profile(runtime)
    workspace = runtime.workspace
    tools = READ_ONLY_TOOLS + %w[apply_patch create_file run_check]
    checks = {'lint' => ['/usr/bin/true']}

    digest = Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes: true, checks:,
      check_safeties: {'lint' => :read_only},
      allowed_tools: tools
    ).catalog_digest

    document = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "modeful",
        "profile_version" => "1.0",
        "canonical_root" => workspace
      },
      "roots" => {"workspace" => workspace},
      "tools" => {"allowed" => tools},
      "policy" => {
        "allow_changes" => true,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => digest,
        "unattended_catalog_digest" => digest
      },
      "checks" => {
        "lint" => {"argv" => ["/usr/bin/true"], "safety" => "read_only"}
      }
    }

    directory = File.join(runtime.dir, 'profiles')
    path = File.join(directory, 'modeful.yaml')
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  def set_approval_profile(rt, name)
    path = File.join(rt.dir, 'config.yaml')
    document = Psych.load_file(path)
    document['approval'] = {'profile' => name}
    File.write(path, Psych.dump(document))
  end

  def check_factory
    lambda do |_options|
      ScriptedModel.new(
        plan: [
          plan_step('read_file', {'path' => 'note.txt'}),
          {
            'goal' => 'run the configured check',
            'done_when' => ['the check exited zero'],
            'steps' => [{
              'id' => 's1', 'purpose' => 'verify the workspace',
              'tool' => 'run_check', 'arguments' => {'name' => 'lint'},
              'verification' => 'the check exits zero'
            }]
          }
        ],
        review: [accepted_review, accepted_review],
        verify: [{'answer' => 'checked', 'satisfied' => true, 'evidence' => ['note.txt']}]
      )
    end
  end

  def bundled_profile_rev(name)
    Tamoz::Approval::PolicyDocument.load_profile(
      Tamoz::Approval.bundled_policy_path, name,
      evidence_symbols: Tamoz::Comms::AuthorityEvidence.members
    ).policy_rev
  end

  def review_rev = bundled_profile_rev('review')

  def auto_rev = bundled_profile_rev('auto')

  def live_profile_name(rt)
    open_runtime(rt) { |runtime| runtime.approval_engine.policy.profile_name }
  end

  def open_runtime(rt)
    runtime = Tamoz::Agent::WorkerRuntime.open(
      Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
      model_factory: ->(profile:) { read_only_factory.call(profile) }
    )
    yield runtime
  ensure
    runtime&.close
  end

  def switch_rows(rt)
    database = SQLite3::Database.new(File.join(rt.dir, 'runtime.sqlite3'), readonly: true)
    rows = database.execute(
      'SELECT switch_id, session_id, actor_id, from_rev, to_rev FROM tamoz_approval_mode_switches'
    )
    database.close
    rows.map { |row| %w[switch_id session_id actor_id from_rev to_rev].zip(row).to_h }
  end

  def decision_rows_where(rt, predicate)
    database = SQLite3::Database.new(File.join(rt.dir, 'runtime.sqlite3'), readonly: true)
    rows = database.execute(
      "SELECT session_id, policy_rev FROM tamoz_approval_decisions WHERE #{predicate}"
    )
    database.close
    rows.map { |row| {'session_id' => row.fetch(0), 'policy_rev' => row.fetch(1)} }
  end

  def fetch_request_row(rt)
    database = SQLite3::Database.new(File.join(rt.dir, 'runtime.sqlite3'), readonly: true)
    row = database.execute(
      "SELECT operation, status FROM tamoz_requests WHERE operation = 'mode_switch'"
    ).first
    database.close
    {'operation' => row&.fetch(0), 'status' => row&.fetch(1)}
  end
end
