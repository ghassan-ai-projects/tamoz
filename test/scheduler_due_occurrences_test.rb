# frozen_string_literal: true

require_relative 'test_helper'

# `next_fire_at` answers the poller's horizon question; `due_occurrences` is
# what `materialize_due` actually CLAIMS, so it decides how much work a pause
# or a crash turns into on the next poll. It was covered only indirectly,
# through the sqlite store, and never at the value boundary that owns the
# arithmetic.
class SchedulerDueOccurrencesTest < Minitest::Test
  Scheduler = Tamoz::Scheduler

  PAYLOAD = "sha256:#{'a' * 64}".freeze
  ANCHOR = 1_700_000_000

  def interval_schedule(**overrides)
    Scheduler::Schedule.new(
      id: 'daily', owner: 'human:op', kind: :interval, expression: '3600',
      start_at: ANCHOR, payload_ref: PAYLOAD, thread_policy: 'thread.default',
      capability_grant: { 'scopes' => ['read'] },
      behavior_version: 'tamoz.agent.session/1',
      delivery_policy: { 'mode' => 'inbox' }, budgets: { 'max_steps' => 10 },
      created_by: 'human:op', created_at: ANCHOR, **overrides
    )
  end

  def at_schedule(expression = '2026-08-03T12:00:00Z', **overrides)
    Scheduler::Schedule.new(
      id: 'one-shot', owner: 'human:op', kind: :at, expression:,
      payload_ref: PAYLOAD, thread_policy: 'thread.default',
      capability_grant: { 'scopes' => ['read'] },
      behavior_version: 'tamoz.agent.session/1',
      delivery_policy: { 'mode' => 'inbox' }, budgets: { 'max_steps' => 10 },
      created_by: 'human:op', created_at: ANCHOR, **overrides
    )
  end

  def test_due_occurrences_catches_up_across_a_missed_window
    schedule = interval_schedule

    assert_equal [ANCHOR], schedule.due_occurrences(now: ANCHOR)
    assert_equal [ANCHOR, ANCHOR + 3_600, ANCHOR + 7_200, ANCHOR + 10_800],
                 schedule.due_occurrences(now: ANCHOR + 10_800),
                 'three missed cadences plus the anchor, oldest first'
  end

  # A cadence that has not elapsed yet does not produce a second occurrence:
  # the boundary is inclusive of `now`, not of the next instant.
  def test_due_occurrences_does_not_anticipate_the_next_cadence
    schedule = interval_schedule

    assert_equal [ANCHOR], schedule.due_occurrences(now: ANCHOR + 3_599)
    assert_equal [ANCHOR, ANCHOR + 3_600], schedule.due_occurrences(now: ANCHOR + 3_600)
  end

  # The limit truncates from the OLDEST end — a long outage must not let the
  # newest occurrence starve the ones that were missed first.
  def test_due_occurrences_truncates_at_the_limit_keeping_the_oldest
    schedule = interval_schedule
    all = schedule.due_occurrences(now: ANCHOR + (20 * 3_600), limit: 100)

    assert_equal 21, all.length
    assert_equal all.first(2), schedule.due_occurrences(now: ANCHOR + (20 * 3_600), limit: 2)
    # The default limit is what an un-parameterized poller gets.
    assert_equal 10, schedule.due_occurrences(now: ANCHOR + (20 * 3_600)).length
  end

  # `anchor` is how the store resumes from the last occurrence it already
  # claimed, rather than replaying from the schedule's own start.
  def test_due_occurrences_resumes_from_an_explicit_anchor
    schedule = interval_schedule
    resumed = ANCHOR + 7_200

    assert_equal [resumed, resumed + 3_600],
                 schedule.due_occurrences(now: resumed + 3_600, anchor: resumed)
  end

  def test_a_paused_schedule_claims_nothing
    assert_empty interval_schedule(enabled: false).due_occurrences(now: ANCHOR + 10_800)
  end

  def test_nothing_is_claimable_before_the_anchor_or_after_the_horizon
    assert_empty interval_schedule.due_occurrences(now: ANCHOR - 1),
                 'nothing is due before the anchor'
    assert_empty interval_schedule(end_at: ANCHOR + 100).due_occurrences(now: ANCHOR + 200),
                 'a schedule past its horizon claims nothing'
  end

  def test_an_anchor_ahead_of_now_claims_nothing
    assert_empty interval_schedule.due_occurrences(now: ANCHOR + 100, anchor: ANCHOR + 10_000)
  end

  # An `at` schedule is one-shot: due exactly once, and never more than once
  # however wide the window or the limit.
  def test_due_occurrences_for_an_at_schedule_is_at_most_one
    instant = Time.utc(2026, 8, 3, 12, 0, 0).to_i
    schedule = at_schedule

    assert_empty schedule.due_occurrences(now: instant - 1)
    assert_equal [instant], schedule.due_occurrences(now: instant)
    assert_equal [instant], schedule.due_occurrences(now: instant + 1_000_000, limit: 10)
  end

  def test_an_at_schedule_outside_its_own_bounds_claims_nothing
    instant = Time.utc(2026, 8, 3, 12, 0, 0).to_i

    assert_empty at_schedule(start_at: instant + 1).due_occurrences(now: instant + 10),
                 "the instant precedes the schedule's own start"
    assert_empty at_schedule(end_at: instant - 1).due_occurrences(now: instant + 10),
                 "the instant is past the schedule's own horizon"
  end
end
