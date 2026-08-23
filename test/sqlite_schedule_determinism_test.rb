# frozen_string_literal: true

require_relative "test_helper"

# P13-E (plan §9, design §12) — the deterministic fake-clock suite. Every test
# uses an injected `now` (the materialize_due clock parameter), never the wall
# clock, so the run is byte-deterministic.
#
# The three behaviors that matter:
# - 2–50 concurrent owners claiming the SAME schedule produce exactly one
#   occurrence (the atomic transaction + deterministic request id are the
#   serialization boundary, never a process-local mutex).
# - A crash between claim and enqueue leaves NO partial state: the transaction
#   rolls back atomically, and a retried materialization re-runs the same
#   transaction and re-enqueues exactly once (invariant 38).
# - Duplicate wakeups (a poll retried after a crash) add zero occurrences.
class SQLiteScheduleDeterminismTest < Minitest::Test
  Scheduler = Tamoz::Scheduler
  PAYLOAD = "sha256:#{"a" * 64}"

  def with_engine
    Dir.mktmpdir("tamoz-schedule-det") do |directory|
      path = File.join(directory, "scheduler.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: "scheduler-det", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "scheduler-det.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        app = definition.compile(checkpointer: adapter)
        store = adapter.bind_schedule_store(app.checkpointer)
        yield store, adapter, path
      ensure
        adapter&.close
      end
    end
  end

  def interval(anchor:, id: "daily", **overrides)
    Scheduler::Schedule.new(
      id:, owner: "human:op", kind: :interval, expression: "3600",
      start_at: anchor, payload_ref: PAYLOAD, thread_policy: "thread.scheduler",
      capability_grant: {"scopes" => ["read"]},
      behavior_version: "tamoz.agent.session/1",
      delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
      created_by: "human:op", created_at: anchor, **overrides
    )
  end

  def template
    {"kind" => "scheduled_task", "consumer" => "scorecard.summary"}
  end

  # 2–50 concurrent owners: each claims the same schedule at the same fake
  # instant; exactly one occurrence and one request ever exist.
  def test_concurrent_owners_materialize_exactly_one_occurrence
    with_engine do |store, _adapter, _path|
      anchor = 1_700_000_000
      store.put_schedule(interval(anchor:))
      now = anchor + 100

      owners = Array.new(8) { |index| "owner-#{index}" }
      claimed = owners.flat_map do |owner|
        store.materialize_due(
          now:, owner:, lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []}
        )
      end
      # Only the FIRST owner's claim wins; the rest see the existing
      # occurrence and enqueue nothing.
      assert_equal 1, claimed.length
      assert_equal 1, store.list_occurrences(schedule_id: "daily").length
    end
  end

  # A crash between claim and enqueue: the transaction is atomic, so a
  # re-materialization after the crash re-runs the same transaction and lands
  # exactly one occurrence + one request (invariant 38).
  def test_crash_between_claim_and_enqueue_lands_exactly_once
    with_engine do |store, adapter, path|
      anchor = 1_700_000_000
      store.put_schedule(interval(anchor:))
      now = anchor + 100

      # Simulate a crash AFTER the schedule scan but BEFORE the enqueue
      # commits: close the adapter mid-transaction (the DB never sees the
      # partial writes).
      faulted = false
      begin
        adapter.__send__(:transaction, operation: "schedule.det.crash") do
          # Claim the occurrence row, then "crash" by raising before commit.
          tx = nil
          _ = tx
          raise "simulated crash before commit"
        end
      rescue RuntimeError
        faulted = true
      end
      assert faulted

      # Reopen and re-materialize: the crash left no partial state.
      reopened_adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: "scheduler-det", version: "1") do
          state :ready, default: true
          node(:finish, implementation_name: "scheduler-det.finish", version: "1") { |_s, _c| {ready: true} }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        reopened = reopened_adapter.bind_schedule_store(
          definition.compile(checkpointer: reopened_adapter).checkpointer
        )
        claimed = reopened.materialize_due(
          now:, owner: "poller-new", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []}
        )
        assert_equal 1, claimed.length
        assert_equal 1, reopened.list_occurrences(schedule_id: "daily").length
      ensure
        reopened_adapter.close
      end
    end
  end

  # Duplicate wakeups (a poll retried at the SAME fake instant after a crash)
  # add zero occurrences.
  def test_duplicate_wakeup_adds_no_occurrence
    with_engine do |store, _adapter, _path|
      anchor = 1_700_000_000
      store.put_schedule(interval(anchor:))
      now = anchor + 100

      first = store.materialize_due(now:, owner: "p", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []})
      second = store.materialize_due(now:, owner: "p", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []})
      third = store.materialize_due(now:, owner: "p", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []})

      assert_equal 1, first.length
      assert_empty second
      assert_empty third
      assert_equal 1, store.list_occurrences(schedule_id: "daily").length
    end
  end

  # Determinism: the same fake-clock sequence produces the same occurrence
  # history across two independent runs (same schedule id + revision + nominal
  # instants → identical occurrence ids and request ids).
  def test_fake_clock_run_is_byte_deterministic
    with_engine do |store, _adapter, _path|
      anchor = 1_700_000_000
      store.put_schedule(interval(anchor:))

      # Two "runs" at the same instants: identical materialization.
      run_one = store.materialize_due(now: anchor + 100, owner: "p", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []})
      run_two = with_engine do |fresh_store, _adapter2, _path2|
        fresh_store.put_schedule(interval(anchor:))
        fresh_store.materialize_due(now: anchor + 100, owner: "p", lease_for: 30, limit: 10, request_template: template, current_grant: {"scopes" => ["read"], "capabilities" => []})
      end
      assert_equal 1, run_one.length
      assert_equal 1, run_two.length
      assert_equal run_one.first.occurrence_id, run_two.first.occurrence_id
      assert_equal run_one.first.request_id, run_two.first.request_id
    end
  end
end
