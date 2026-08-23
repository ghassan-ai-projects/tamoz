# frozen_string_literal: true

# `tamoz schedule` through the public CLI.
#
# The scorecard proves the behaviour that matters most — an interval schedule
# produces exactly one logical occurrence. This file covers the management
# surface around it: the lifecycle verbs, their refusals, and the rule that a
# schedule is a way of putting work on the ordinary queue rather than a second
# way of running it.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentScheduleTest < Minitest::Test
  include AutonomyCase

  def test_schedule_lifecycle_add_pause_resume_remove
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")

      assert_equal 0, rt.cli(%W[schedule add --id nightly --interval 3600 --task Read\ note.txt --json]),
                   rt.err
      added = JSON.parse(rt.out)
      assert_equal "nightly", added.fetch("id")
      assert_equal "interval", added.fetch("kind")
      assert added.fetch("enabled")

      rt.cli(%w[schedule list --json])
      listed = JSON.parse(rt.out).fetch("schedules")
      assert_equal 1, listed.length
      assert_equal "Read note.txt", listed.first.fetch("task")

      # Paused: a due instant must not materialize.
      assert_equal 0, rt.cli(%w[schedule pause nightly --json]), rt.err
      rt.cli(%w[schedule show nightly --json])
      refute JSON.parse(rt.out).fetch("enabled")

      rt.cli(%w[worker --once --json], factory: read_only_factory)
      assert_empty rt.occurrences("nightly"), "a paused schedule fired"

      # Resumed: the same schedule, not a new one.
      assert_equal 0, rt.cli(%w[schedule resume nightly --json]), rt.err
      rt.cli(%w[schedule show nightly --json])
      resumed = JSON.parse(rt.out)
      assert resumed.fetch("enabled")
      assert_equal added.fetch("id"), resumed.fetch("id")

      rt.cli(%w[worker --once --json], factory: read_only_factory)
      occurrences = rt.occurrences("nightly")
      refute_empty occurrences, "a resumed schedule did not fire"
      assert_equal "succeeded", occurrences.first.fetch("state"), occurrences.first.inspect

      # Removed: stops firing, keeps its history.
      assert_equal 0, rt.cli(%w[schedule remove nightly --json]), rt.err
      rt.cli(%w[schedule list --json])
      assert_empty JSON.parse(rt.out).fetch("schedules").select { |entry| entry.fetch("enabled") }
      refute_empty rt.occurrences("nightly"),
                   "removing a schedule destroyed the evidence of what it ran"
    end
  end

  # A schedule names the approval profile its occurrences run under. The flag
  # is optional: absent means the default profile, not no profile.
  def test_schedule_add_names_an_approval_profile
    with_runtime do |rt|
      assert_equal 0,
                   rt.cli(%W[schedule add --id nightly --interval 3600 --task X --approval-profile unattended --json]),
                   rt.err
      rt.cli(%w[schedule show nightly --json])
      assert_equal "unattended", JSON.parse(rt.out).fetch("approval_profile")

      assert_equal 0, rt.cli(%W[schedule add --id plain --interval 3600 --task X --json]), rt.err
      rt.cli(%w[schedule show plain --json])
      assert_equal "implement", JSON.parse(rt.out).fetch("approval_profile")
    end
  end

  def test_status_projects_schedule_authority_and_recovery_state
    with_runtime do |rt|
      rt.cli(%W[schedule add --id nightly --interval 3600 --task Read note.txt])

      rt.cli(%w[status --json])
      scheduled = JSON.parse(rt.out).fetch("scheduled_work").fetch(0)
      assert_equal "nightly", scheduled.fetch("schedule_id")
      assert_equal "not_materialized", scheduled.fetch("execution_state")
      assert_equal "scheduled", scheduled.fetch("phase")
      assert_equal "granted", scheduled.fetch("capability_state")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, scheduled.fetch("grant_revision"))
      assert_equal "wait_for_due_occurrence", scheduled.fetch("next_action")
      refute scheduled.key?("occurrence_id"), "status fabricated an occurrence"

      rt.cli(%w[schedule pause nightly])
      rt.cli(%w[status --json])
      paused = JSON.parse(rt.out).fetch("scheduled_work").fetch(0)
      assert_equal "paused", paused.fetch("phase")
      assert_equal "schedule_disabled", paused.fetch("pause_reason")
      assert_equal "resume_schedule", paused.fetch("next_action")
    end
  end

  # The reason the tombstone exists: a later `schedule add` reusing the id must
  # not inherit the removed schedule's stored task.
  #
  # It did not hold. `tombstone_schedule` deleted the payload with a blind
  # write, which the versioned store refuses, and a blanket rescue swallowed
  # the refusal — so the tombstone was written and the retired task text stayed
  # in the store on every single removal.
  def test_removing_a_schedule_retires_its_stored_task
    with_runtime do |rt|
      rt.cli(%W[schedule add --id nightly --interval 3600 --task Secret\ task])
      assert_equal 0, rt.cli(%w[schedule remove nightly --json]), rt.err

      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        assert_nil runtime.schedule_payload("nightly"),
                   "the removed schedule's task survived its tombstone"
      ensure
        runtime.close
      end
    end
  end

  # Pausing must survive an edit. Otherwise "pause it while I look into this"
  # silently un-pauses the next time anyone touches the schedule.
  def test_pause_survives_a_redefinition
    with_runtime do |rt|
      rt.cli(%W[schedule add --id nightly --interval 3600 --task First])
      rt.cli(%w[schedule pause nightly])
      rt.cli(%W[schedule add --id nightly --interval 7200 --task Second --json])

      rt.cli(%w[schedule show nightly --json])
      document = JSON.parse(rt.out)
      refute document.fetch("enabled"), "an edit un-paused a paused schedule"
      assert_equal "Second", document.fetch("task")
    end
  end

  def test_run_now_queues_the_task_without_inventing_an_occurrence
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[schedule add --id nightly --interval 86400 --task Read\ note.txt])
      # Paused, so the only work the worker can find is the one `run-now` queued.
      # This also pins the useful property that `run-now` works on a paused
      # schedule — "run it now anyway" is most of why an operator reaches for it.
      rt.cli(%w[schedule pause nightly])

      assert_equal 0, rt.cli(%w[schedule run-now nightly --json]), rt.err
      queued = JSON.parse(rt.out)
      assert_equal "queued", queued.fetch("status")

      # An occurrence means "this schedule fired at this nominal instant".
      # `run-now` is an operator queueing a task, so the history stays honest.
      assert_empty rt.occurrences("nightly"),
                   "run-now fabricated a scheduled occurrence"

      rt.cli(%w[worker --once --json], factory: read_only_factory)
      completed = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completed.length
    end
  end

  def test_schedule_refuses_a_malformed_definition
    with_runtime do |rt|
      # No task.
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR,
                   rt.cli(%w[schedule add --id nightly --interval 60])
      assert_match(/--task/, rt.err)

      # Neither interval nor at.
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR,
                   rt.cli(%W[schedule add --id nightly --task Something])
      assert_match(/--interval or --at/, rt.err)

      # Both.
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR,
                   rt.cli(%W[schedule add --id n --interval 60 --at 2030-01-01T00:00:00Z --task X])
      assert_match(/mutually exclusive/, rt.err)

      # An id that would escape the runtime directory's namespace.
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR,
                   rt.cli(%W[schedule add --id ../evil --interval 60 --task X])
      assert_match(/must be letters/, rt.err)
    end
  end

  def test_unknown_schedule_is_a_clear_error
    with_runtime do |rt|
      assert_equal 1, rt.cli(%w[schedule show nope --json])
      assert_match(/no schedule "nope"/, rt.err)
      assert_equal 1, rt.cli(%w[schedule pause nope])
      assert_equal 1, rt.cli(%w[schedule run-now nope])
    end
  end

  # A one-shot `--at` schedule in the future must not fire yet, and the same
  # schedule in the past fires exactly once.
  def test_at_schedule_fires_once_and_not_early
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      future = (Time.now + 3600).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      rt.cli(%W[schedule add --id later --at #{future} --task Read\ note.txt])

      rt.cli(%w[worker --once --json], factory: read_only_factory)
      assert_empty rt.occurrences("later"), "a future one-shot fired early"

      past = (Time.now - 60).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      rt.cli(%W[schedule add --id soon --at #{past} --task Read\ note.txt])
      2.times { rt.cli(%w[worker --once --json], factory: read_only_factory) }

      assert_equal 1, rt.occurrences("soon").length,
                   "a one-shot schedule fired more than once"
    end
  end
end
