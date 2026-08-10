# frozen_string_literal: true

require_relative "test_helper"

class SQLiteDeletionTest < Minitest::Test
  def test_tombstone_blocks_new_work_and_purge_retains_idempotent_receipt
    Dir.mktmpdir("tamoz-deletion") do |directory|
      limits = Tamoz::SQLite::Limits.new(deletion_retention: 0)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits:
      )
      app = definition.compile(checkpointer: adapter)
      request = app.durable_runner.deliver(
        {"amount" => 2},
        thread: "thread.delete",
        request_id: "request.initial"
      )
      assert request.terminal?
      snapshot = app.state(thread: "thread.delete")
      adapter.store.put("application", "survives", true)
      authorization = Tamoz::SQLite::DeletionAuthorization.new(
        actor: "test.operator",
        reason: "explicit test cleanup"
      )

      report = adapter.tombstone_thread(
        thread_id: "thread.delete",
        expected_tips: {[] => snapshot.checkpoint_id},
        authorization:
      )
      assert_equal :active, report.status
      assert_equal 1, report.namespace_count
      assert_operator report.checkpoint_count, :>=, 2
      assert_equal report, adapter.tombstone_thread(
        thread_id: "thread.delete",
        expected_tips: {[] => snapshot.checkpoint_id},
        authorization:
      )
      assert_raises(Tamoz::CheckpointConflictError) do
        app.durable_runner.submit(
          {"amount" => 1},
          thread: "thread.delete",
          request_id: "request.blocked"
        )
      end

      receipt = adapter.purge_thread(tombstone_id: report.tombstone_id)
      assert_equal receipt, adapter.purge_thread(tombstone_id: report.tombstone_id)
      assert_equal receipt, adapter.deletion_receipt(tombstone_id: report.tombstone_id)
      assert_equal true, adapter.store.get("application", "survives").value
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  def test_tip_mismatch_and_live_lease_fail_closed
    Dir.mktmpdir("tamoz-deletion") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3")
      )
      app = definition.compile(checkpointer: adapter)
      app.durable_runner.deliver(
        {"amount" => 1},
        thread: "thread.guarded",
        request_id: "request.initial"
      )
      snapshot = app.state(thread: "thread.guarded")
      authorization = Tamoz::SQLite::DeletionAuthorization.new(
        actor: "test.operator",
        reason: "guard test"
      )
      assert_raises(Tamoz::CheckpointConflictError) do
        adapter.tombstone_thread(
          thread_id: "thread.guarded",
          expected_tips: {[] => "wrong"},
          authorization:
        )
      end

      app.checkpointer.open_writer(
        thread_id: "thread.guarded",
        namespace: [],
        owner_id: "owner.live",
        ttl: app.checkpointer.writer_ttl
      ) do
        assert_raises(Tamoz::CheckpointConflictError) do
          adapter.tombstone_thread(
            thread_id: "thread.guarded",
            expected_tips: {[] => snapshot.checkpoint_id},
            authorization:
          )
        end
      end
    ensure
      adapter&.close
    end
  end

  # Invariant 54: purge explicitly deletes comms rows — conversations, outbox
  # rows, requests, decisions and prompts are counted and removed, never left
  # orphaned by cascade.
  def test_purge_explicitly_deletes_comms_rows_and_counts_them_in_the_receipt
    Dir.mktmpdir("tamoz-deletion") do |directory|
      limits = Tamoz::SQLite::Limits.new(deletion_retention: 0)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits:
      )
      app = definition.compile(checkpointer: adapter)
      app.durable_runner.deliver(
        {"amount" => 1},
        thread: "thread.comms",
        request_id: "request.initial"
      )
      snapshot = app.state(thread: "thread.comms")
      now = Time.utc(2026, 8, 10, 12, 0, 0)
      store = adapter.bind_comms_store(app.checkpointer)

      route = Tamoz::Comms::Conversation.new(
        surface_id: "telegram-ops", surface_revision: 1,
        conversation_id: "telegram:chat:22222222", thread_id: "thread.comms",
        profile_id: "ops", bound_at: now
      ).wire
      store.bind_conversation(route, now:)
      delivery = Tamoz::Comms::Delivery.build(
        conversation_id: "telegram:chat:22222222", kind: "answer", text: "ok",
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: "b" * 64
      ).wire
      store.append_delivery(delivery, surface_id: "telegram-ops", capacity: 10, now:)
      decision = Tamoz::Comms::DecisionRecord.build(
        thread_id: "thread.comms", occurrence_id: "req-1",
        interrupts: [{task_id: "t", call_index: 0, descriptor: {"kind" => "approve_tool"}}],
        direction: :deny, actor_kind: "os_user", actor_id: "501", source: "cli",
        decided_at: now
      )
      adapter.bind_comms_decision_store.insert_decision(decision.wire)

      authorization = Tamoz::SQLite::DeletionAuthorization.new(
        actor: "test.operator",
        reason: "explicit comms cleanup"
      )
      report = adapter.tombstone_thread(
        thread_id: "thread.comms",
        expected_tips: {[] => snapshot.checkpoint_id},
        authorization:
      )
      assert_equal :active, report.status
      assert_equal 1, report.request_count

      receipt = adapter.purge_thread(tombstone_id: report.tombstone_id)
      assert_equal 1, receipt.counts.fetch("comms_routes")
      assert_equal 1, receipt.counts.fetch("comms_outbox")
      assert_equal 1, receipt.counts.fetch("comms_decisions")
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  private

  def definition
    Tamoz.graph(name: "deletion-test", version: "1") do
      state :amount, default: 0
      state :total, default: 0
      node(:add, implementation_name: "deletion.add", version: "1") do |state, _context|
        {total: state.fetch(:amount)}
      end
      edge Tamoz::START, :add
      edge :add, Tamoz::END
    end
  end
end
