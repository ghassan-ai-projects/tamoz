# frozen_string_literal: true

require_relative "test_helper"

# P13-D (SCHEDULER_DESIGN §3/§5, plan §3) — the validated Schedule and
# Occurrence values, content-addressed revisions, deterministic occurrence
# identity, the closed state machine, and the at/interval next-fire calculus.
#
# Every gate is proven by attempting the violation and asserting the refusal.
class SchedulerValuesTest < Minitest::Test
  Scheduler = Tamoz::Scheduler

  PAYLOAD = "sha256:#{"a" * 64}"
  ANCHOR = 1_700_000_000

  def interval_schedule(**overrides)
    Scheduler::Schedule.new(
      id: "daily", owner: "human:op", kind: :interval, expression: "3600",
      start_at: ANCHOR, payload_ref: PAYLOAD, thread_policy: "thread.default",
      capability_grant: {"scopes" => ["read"]},
      behavior_version: "tamoz.agent.session/1",
      approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
      delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
      created_by: "human:op", created_at: ANCHOR, **overrides
    )
  end

  def at_schedule(expression = "2026-08-03T12:00:00Z", **overrides)
    Scheduler::Schedule.new(
      id: "one-shot", owner: "human:op", kind: :at, expression:,
      payload_ref: PAYLOAD, thread_policy: "thread.default",
      capability_grant: {"scopes" => ["read"]},
      behavior_version: "tamoz.agent.session/1",
      approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
      delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
      created_by: "human:op", created_at: ANCHOR, **overrides
    )
  end

  # --- P13-D: values -------------------------------------------------------

  def test_interval_schedule_validates_and_computes_next_instants
    schedule = interval_schedule
    assert_equal :interval, schedule.kind
    assert_equal 1, schedule.revision
    assert schedule.enabled
    assert schedule.definition_digest.start_with?("sha256:")

    # Anchor at ANCHOR, cadence 3600: the next future instant is anchor+3600.
    assert_equal ANCHOR + 3_600, schedule.next_fire_at(ANCHOR + 100)
    assert_equal ANCHOR + 7_200, schedule.next_fire_at(ANCHOR + 3_600 + 100)
    # Before the anchor: the first occurrence is at the anchor.
    assert_equal ANCHOR, schedule.next_fire_at(ANCHOR - 500)
  end

  def test_at_schedule_is_one_shot_utc
    instant = Time.utc(2026, 8, 3, 12, 0, 0).to_i
    schedule = at_schedule
    assert_equal instant, schedule.next_fire_at(instant - 10)
    # Once the instant passes, no further occurrence exists.
    assert_nil schedule.next_fire_at(instant + 10)
  end

  def test_definition_digest_binds_every_field_and_changes_per_revision
    base = interval_schedule
    edited = interval_schedule(misfire_policy: :skip)
    assert_equal base.revision, edited.revision
    refute_equal base.definition_digest, edited.definition_digest
    # Same definition → same digest on every construction.
    assert_equal base.definition_digest, interval_schedule.definition_digest
  end

  def test_validation_refuses_bad_values
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(kind: :cron) }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(expression: "abc") }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(expression: "-10") }
    assert_raises(Tamoz::ConfigurationError) { at_schedule("not-an-instant") }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(id: "Bad ID") }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(misfire_policy: :explode) }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(payload_ref: "not-a-digest") }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(revision: 0) }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(start_at: 200, end_at: 100) }
    assert_raises(Tamoz::ConfigurationError) { interval_schedule(budgets: {"max_steps" => -1}) }
  end

  def test_enabled_and_horizon_control_next_fire
    disabled = interval_schedule(enabled: false)
    assert_nil disabled.next_fire_at(ANCHOR + 100)

    ended = interval_schedule(end_at: ANCHOR + 1_000)
    assert_nil ended.next_fire_at(ANCHOR + 5_000)
    assert_equal ANCHOR + 3_600, ended.next_fire_at(ANCHOR + 100)
  end

  # --- P13-D: jitter -------------------------------------------------------

  def test_jitter_is_deterministic_from_occurrence_id_within_the_window
    schedule = interval_schedule(jitter_window: 300)
    first = schedule.jitter_for("occurrence-A")
    second = schedule.jitter_for("occurrence-A")
    assert_equal first, second
    assert_operator first, :>=, 0
    assert_operator first, :<, 300
    # A different occurrence id may jitter differently.
    other = schedule.jitter_for("occurrence-B")
    refute_equal first, other
    # Zero window → no jitter at all.
    assert_equal 0, interval_schedule.jitter_for("anything")
  end

  # --- P13-D: occurrence identity ------------------------------------------

  def test_occurrence_identity_is_deterministic_and_request_id_derives_from_it
    one = Scheduler::Occurrence.new(
      schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
      created_at: ANCHOR
    )
    two = Scheduler::Occurrence.new(
      schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
      created_at: ANCHOR
    )
    assert_equal one.occurrence_id, two.occurrence_id
    assert_equal one.request_id, two.request_id
    # The request id is a digest OF the identity.
    assert_equal(
      Scheduler::Occurrence.request_id(one.occurrence_id), one.request_id
    )
    # A different nominal instant is a DIFFERENT occurrence.
    other = Scheduler::Occurrence.new(
      schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR + 3_600,
      created_at: ANCHOR
    )
    refute_equal one.occurrence_id, other.occurrence_id
  end

  # --- P13-D: the closed state machine -------------------------------------

  def test_occurrence_state_machine_is_closed_and_typed
    occurrence = Scheduler::Occurrence.new(
      schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
      created_at: ANCHOR
    )
    assert_equal :due, occurrence.state
    refute occurrence.terminal?

    claimed = occurrence.claimed(fence: 1, owner: "poller", now: ANCHOR + 1)
    assert_equal :claimed, claimed.state
    assert_equal 1, claimed.fence

    enqueued = claimed.enqueued(fence: 1, now: ANCHOR + 2)
    assert_equal :enqueued, enqueued.state
    refute enqueued.terminal?, "delivery is never execution success (no false green)"

    running = enqueued.running("exec-1", now: ANCHOR + 3)
    assert_equal :running, running.state

    succeeded = running.succeeded("exec-1", {"ok" => true}, now: ANCHOR + 4)
    assert_equal :succeeded, succeeded.state
    assert succeeded.terminal?

    # Every transition guard is enforced by ATTEMPTING the violation.
    assert_raises(Scheduler::SchedulerError) { occurrence.enqueued(fence: 1, now: ANCHOR + 2) }
    assert_raises(Scheduler::SchedulerError) { occurrence.running("exec", now: ANCHOR + 3) }
    assert_raises(Scheduler::SchedulerError) { claimed.succeeded("e", {}, now: ANCHOR + 4) }
    assert_raises(Scheduler::SchedulerError) { succeeded.running("e", now: ANCHOR + 5) }
    assert_raises(Scheduler::SchedulerError) { succeeded.skipped("late", now: ANCHOR + 5) }
  end

  def test_skipped_and_coalesced_are_typed_due_terminals
    occurrence = Scheduler::Occurrence.new(
      schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
      created_at: ANCHOR
    )
    skipped = occurrence.skipped("limit", now: ANCHOR + 1)
    assert_equal :skipped, skipped.state
    assert_equal "limit", skipped.reason
    assert skipped.terminal?

    coalesced = occurrence.coalesced("sha256:into", now: ANCHOR + 1)
    assert_equal :coalesced, coalesced.state
    assert_equal "sha256:into", coalesced.reason
    assert coalesced.terminal?

    # A claimed occurrence can no longer be skipped.
    claimed = occurrence.claimed(fence: 1, owner: "poller", now: ANCHOR + 1)
    assert_raises(Scheduler::SchedulerError) { claimed.skipped("limit", now: ANCHOR + 2) }
  end

  def test_occurrence_validation_refuses_bad_values
    assert_raises(Scheduler::SchedulerError) do
      Scheduler::Occurrence.new(
        schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: 0,
        created_at: ANCHOR
      )
    end
    assert_raises(Scheduler::SchedulerError) do
      Scheduler::Occurrence.new(
        schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
        not_before: ANCHOR - 1, created_at: ANCHOR
      )
    end
    assert_raises(Scheduler::SchedulerError) do
      Scheduler::Occurrence.new(
        schedule_id: "daily", schedule_revision: 1, nominal_fire_at_utc: ANCHOR,
        state: :bogus, created_at: ANCHOR
      )
    end
  end
end
