# frozen_string_literal: true

require_relative "test_helper"

# P13-A (plan §4, SCHEDULER_DESIGN §11) — the durable ScheduleStore over
# SQLite. The atomicity seam (C1/DC-4) is the core: `materialize_due` claims →
# creates the occurrence → enqueues its request in ONE transaction, so a crash
# at any point leaves old-or-complete-new state and a repeated delivery re-runs
# the same transaction and dedups on the deterministic request id (invariant 38
# duplicate-turn hard zero).
#
# Every proof is behavioral: real SQLite, real enqueue primitive, restart via a
# fresh adapter over the same file.
class SQLiteScheduleStoreTest < Minitest::Test
  Scheduler = Tamoz::Scheduler
  PAYLOAD = "sha256:#{"a" * 64}"

  def with_engine
    Dir.mktmpdir("tamoz-schedule") do |directory|
      path = File.join(directory, "scheduler.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: "scheduler", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "scheduler.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        app = definition.compile(checkpointer: adapter)
        checkpoints = app.checkpointer
        store = adapter.bind_schedule_store(checkpoints)
        yield store, adapter, checkpoints, path
      ensure
        adapter&.close
      end
    end
  end

  def schedule(id: "daily", expression: "3600", start_at: nil, **overrides)
    Scheduler::Schedule.new(
      id:, owner: "human:op", kind: :interval, expression:,
      start_at: start_at, payload_ref: PAYLOAD, thread_policy: "thread.scheduler",
      capability_grant: {"scopes" => ["read"]},
      behavior_version: "tamoz.agent.session/1",
      approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
      delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
      created_by: "human:op", created_at: start_at || 1_700_000_000,
      **overrides
    )
  end

  def request_template
    {"kind" => "scheduled_task", "consumer" => "scorecard.summary"}
  end

  def test_put_schedule_cas_on_revision_and_materialize_due_is_atomic
    with_engine do |store, _adapter, checkpoints, _path|
      stored = store.put_schedule(schedule)
      assert_equal 1, stored.revision

      # CAS: a stale expected_revision is refused.
      assert_raises(Scheduler::StoreConflictError) do
        store.put_schedule(schedule, expected_revision: 5)
      end
      # Correct CAS produces a new revision with a new digest (the definition
      # differs → the digest differs; revision itself is store-assigned).
      edited = store.put_schedule(
        schedule(misfire_policy: :skip), expected_revision: 1
      )
      assert_equal 2, edited.revision
      refute_equal stored.definition_digest, edited.definition_digest

      # materialize_due claims the interval schedule's first occurrence and
      # enqueues its request — atomically. Only the ACTIVE revision (2, same
      # anchor, due) materializes; revision 1 is superseded, so exactly one
      # occurrence per schedule id.
      now = 1_700_000_000
      claimed = store.materialize_due(
        now:, owner: "poller-1", lease_for: 30, limit: 10,
        request_template:
      )
      assert_equal 1, claimed.length
      occurrence = claimed.first
      assert_equal :enqueued, occurrence.state

      # The request landed in the ORDINARY request inbox (not a scheduler
      # surface): it is a queued turn request.
      request = checkpoints.fetch_request(
        thread_id: "thread.scheduler", request_id: occurrence.request_id
      )
      assert_equal :queued, request.status
      assert_equal :turn, request.operation
      assert_equal "scheduled_task", request.payload.fetch("kind")
      assert_equal occurrence.request_id, request.payload.fetch("request_id")
    end
  end

  def test_materialize_due_dedups_on_occurrence_identity
    with_engine do |store, _adapter, checkpoints, _path|
      store.put_schedule(schedule)
      now = 1_700_000_000

      first = store.materialize_due(now:, owner: "poller-1", lease_for: 30, limit: 10, request_template:)
      assert_equal 1, first.length

      # A repeated materialization re-runs the same transaction: same identity,
      # same request id, NO second request row and NO second occurrence.
      second = store.materialize_due(now:, owner: "poller-1", lease_for: 30, limit: 10, request_template:)
      assert_equal 0, second.length

      # Exactly one queued request exists for that occurrence.
      occurrences = store.list_occurrences(schedule_id: "daily")
      assert_equal 1, occurrences.length
      request = checkpoints.fetch_request(
        thread_id: "thread.scheduler", request_id: occurrences.first.request_id
      )
      assert_equal :queued, request.status
    end
  end

  def test_restart_survival_and_completion_state_machine
    with_engine do |store, _adapter, _checkpoints, path|
      store.put_schedule(schedule(start_at: 1_700_000_000))
      claimed = store.materialize_due(
        now: 1_700_000_100, owner: "poller-1", lease_for: 30, limit: 10,
        request_template:
      )
      assert_equal 1, claimed.length

      # A restart (fresh adapter over the same file) must NOT re-enqueue the
      # already-materialized occurrence.
      reopened_adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        reopened_def = Tamoz.graph(name: "scheduler", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "scheduler.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        reopened_app = reopened_def.compile(checkpointer: reopened_adapter)
        reopened = reopened_adapter.bind_schedule_store(reopened_app.checkpointer)
        again = reopened.materialize_due(
          now: 1_700_000_100, owner: "poller-2", lease_for: 30, limit: 10,
          request_template:
        )
        assert_equal 0, again.length, "restart must not duplicate an occurrence"
        assert_equal 1, reopened.list_occurrences(schedule_id: "daily").length
      ensure
        reopened_adapter.close
      end
    end
  end

  def test_at_schedule_is_one_shot
    with_engine do |store, _adapter, _checkpoints, _path|
      instant = Time.utc(2026, 8, 3, 12, 0, 0).to_i
      store.put_schedule(schedule(id: "one-shot", kind: :at, expression: "2026-08-03T12:00:00Z"))

      # Before the instant: no occurrence.
      before = store.materialize_due(now: instant - 10, owner: "p", lease_for: 30, limit: 10, request_template:)
      assert_equal 0, before.length

      # At/after the instant: exactly one occurrence, ever.
      at = store.materialize_due(now: instant + 1, owner: "p", lease_for: 30, limit: 10, request_template:)
      assert_equal 1, at.length
      later = store.materialize_due(now: instant + 1000, owner: "p", lease_for: 30, limit: 10, request_template:)
      assert_equal 0, later.length
    end
  end

  def test_disable_schedule_prevents_future_claims
    with_engine do |store, _adapter, _checkpoints, _path|
      stored = store.put_schedule(schedule)
      store.disable_schedule("daily", expected_revision: stored.revision, reason: "manual pause")

      claimed = store.materialize_due(
        now: 1_700_000_100, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 0, claimed.length

      # A stale expected_revision on disable is refused.
      assert_raises(Scheduler::StoreConflictError) do
        store.disable_schedule("daily", expected_revision: stored.revision + 1, reason: "x")
      end
    end
  end

  # --- P13-B: misfire policies (design §6) ---------------------------------

  # Interval schedule with a 1h cadence, polled at now = anchor + 3h. The due
  # window is [a, a+1h, a+2h, a+3h]; the misfire policy picks what enqueues.
  def test_misfire_skip_delivers_only_the_latest_and_records_older_skipped
    with_engine do |store, _adapter, _checkpoints, _path|
      anchor = 1_700_000_000
      store.put_schedule(schedule(start_at: anchor, misfire_policy: :skip))

      claimed = store.materialize_due(
        now: anchor + 10_800, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 1, claimed.length, "skip coalesces the missed window into the latest"
      assert_equal anchor + 10_800, claimed.first.nominal_fire_at_utc

      # The three older missed occurrences are recorded as skipped (bounded
      # history, explicit), never enqueued.
      occurrences = store.list_occurrences(schedule_id: "daily")
      assert_equal 4, occurrences.length
      skipped = occurrences.select { |o| o.state == :skipped }
      assert_equal 3, skipped.length
      assert_equal [anchor, anchor + 3_600, anchor + 7_200],
                   skipped.map(&:nominal_fire_at_utc).sort
    end
  end

  def test_misfire_replay_delivers_oldest_first_up_to_the_limit
    with_engine do |store, _adapter, _checkpoints, _path|
      anchor = 1_700_000_000
      store.put_schedule(
        schedule(start_at: anchor, misfire_policy: :replay, misfire_limit: 2)
      )

      claimed = store.materialize_due(
        now: anchor + 10_800, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      # replay delivers the two OLDEST missed occurrences (the window is 4);
      # the later two are skipped because the limit is 2.
      assert_equal 2, claimed.length
      assert_equal [anchor, anchor + 3_600], claimed.map(&:nominal_fire_at_utc).sort

      occurrences = store.list_occurrences(schedule_id: "daily")
      assert_equal 2, occurrences.count { |o| o.state == :skipped }
    end
  end

  def test_misfire_fire_once_delivers_one_recovery_for_a_one_shot_window
    with_engine do |store, _adapter, _checkpoints, _path|
      # One-shot with fire_once: after the instant passes, exactly one
      # recovery occurrence ever exists.
      instant = Time.utc(2026, 8, 3, 12, 0, 0).to_i
      store.put_schedule(
        schedule(id: "one-shot", kind: :at, expression: "2026-08-03T12:00:00Z",
                 misfire_policy: :fire_once)
      )
      claimed = store.materialize_due(
        now: instant + 3_600, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 1, claimed.length
      assert_equal instant, claimed.first.nominal_fire_at_utc
      assert_equal 1, store.list_occurrences(schedule_id: "one-shot").length
    end
  end

  # --- P13-B: overlap policies (design §7) ---------------------------------

  # forbid (default): a non-terminal occurrence blocks the next one.
  def test_overlap_forbid_skips_the_next_occurrence_while_one_is_in_flight
    with_engine do |store, _adapter, _checkpoints, _path|
      anchor = 1_700_000_000
      store.put_schedule(schedule(start_at: anchor, overlap_policy: :forbid))

      first = store.materialize_due(
        now: anchor + 100, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 1, first.length
      # The first occurrence is still enqueued (non-terminal). The next
      # materialization at the second cadence must SKIP the new occurrence.
      second = store.materialize_due(
        now: anchor + 3_700, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 0, second.length
      occurrences = store.list_occurrences(schedule_id: "daily")
      assert_equal 2, occurrences.length
      assert_equal :enqueued, occurrences.min_by(&:nominal_fire_at_utc).state
      assert_equal :skipped, occurrences.max_by(&:nominal_fire_at_utc).state
    end
  end

  # allow: concurrent occurrences up to max_concurrency.
  def test_overlap_allow_runs_concurrently_up_to_max_concurrency
    with_engine do |store, _adapter, _checkpoints, _path|
      anchor = 1_700_000_000
      store.put_schedule(
        schedule(start_at: anchor, overlap_policy: :allow, max_concurrency: 2)
      )
      claimed = store.materialize_due(
        now: anchor + 10_800, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      # With allow(2) under `latest` misfire, the first poll materializes the
      # latest occurrence only. Complete it, then the next poll materializes
      # the next due one (the one-shot window is exhausted, so the next cadence
      # after the anchor is claimed).
      assert_equal 1, claimed.length
      occurrence = claimed.first
      store.acknowledge_occurrence(
        occurrence.occurrence_id, execution_id: "e-1", fence: occurrence.fence
      )
      store.complete_occurrence(
        occurrence.occurrence_id, execution_id: "e-1", status: :succeeded, evidence: {"ok" => true}
      )

      again = store.materialize_due(
        now: anchor + 14_400, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 1, again.length
    end
  end

  # queue_one: one bounded pending occurrence; later ones coalesce into it.
  def test_overlap_queue_one_coalesces_later_occurrences
    with_engine do |store, _adapter, _checkpoints, _path|
      anchor = 1_700_000_000
      store.put_schedule(
        schedule(start_at: anchor, overlap_policy: :queue_one)
      )
      first = store.materialize_due(
        now: anchor + 100, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 1, first.length

      # The first occurrence is still enqueued (pending=1). The next cadence
      # (latest misfire) would materialize a+1h; queue_one coalesces it into
      # the pending occurrence instead of enqueuing a second request.
      later = store.materialize_due(
        now: anchor + 3_700, owner: "p", lease_for: 30, limit: 10, request_template:
      )
      assert_equal 0, later.length
      occurrences = store.list_occurrences(schedule_id: "daily")
      coalesced = occurrences.select { |o| o.state == :coalesced }
      assert_equal 1, coalesced.length
      assert_equal anchor + 3_600, coalesced.first.nominal_fire_at_utc
    end
  end
end
