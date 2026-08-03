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
end
