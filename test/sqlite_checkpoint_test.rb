# frozen_string_literal: true

require_relative "test_helper"

class SQLiteCheckpointTest < Minitest::Test
  def test_durable_graph_rejects_public_mutation_and_recovers_history_after_reopen
    Dir.mktmpdir("tamoz-sqlite-checkpoint") do |directory|
      path = File.join(directory, "tamoz.db")
      definition = counter_definition
      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = definition.compile(checkpointer: adapter)

      assert_raises(Tamoz::ConfigurationError) do
        app.invoke(
          {},
          thread: "thread.counter",
          request_id: "request.counter",
          execution_id: "execution.counter"
        )
      end
      result = invoke_durable(
        app,
        thread: "thread.counter",
        request_id: "request.counter",
        execution_id: "execution.counter"
      )
      assert_equal 1, result.state.fetch(:count)
      assert_equal [1, 0], app.history(thread: "thread.counter").map(&:sequence)
      adapter.close

      reopened = Tamoz::SQLite::Adapter.new(path:)
      recovered = definition.compile(checkpointer: reopened)
      assert_equal 1, recovered.state(thread: "thread.counter").state.fetch(:count)
      assert_equal(
        [[1, 1], [0, 0]],
        recovered.history(thread: "thread.counter").map do |snapshot|
          [snapshot.sequence, snapshot.state.fetch(:count)]
        end
      )
      assert reopened.integrity_check.fetch("ok")
      reopened.close
    end
  end

  def test_lease_fences_increase_after_release_and_reject_concurrent_owner
    with_bound_store do |adapter, store|
      fences = []
      store.open_writer(
        thread_id: "thread.lease",
        namespace: [],
        owner_id: "owner.a",
        ttl: adapter.limits.lease_ttl
      ) do |writer|
        fences << writer.fence
        assert_raises(Tamoz::CheckpointConflictError) do
          store.open_writer(
            thread_id: "thread.lease",
            namespace: [],
            owner_id: "owner.b",
            ttl: adapter.limits.lease_ttl
          ) { flunk "concurrent owner acquired the lease" }
        end
      end
      store.open_writer(
        thread_id: "thread.lease",
        namespace: [],
        owner_id: "owner.c",
        ttl: adapter.limits.lease_ttl
      ) { |writer| fences << writer.fence }

      assert_equal [1, 2], fences
    end
  end

  def test_expired_owner_cannot_write_after_takeover
    Dir.mktmpdir("tamoz-sqlite-stale") do |directory|
      limits = Tamoz::SQLite::Limits.new(lease_ttl: 0.1)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        limits:
      )
      thread_id = "thread.stale"
      namespace = Tamoz::SQLite.const_get(:Wire, false).namespace([])
      stale = adapter.__send__(
        :acquire_lease,
        thread_id:,
        namespace:,
        owner_id: "owner.stale",
        ttl: 0.1
      )
      sleep 0.12
      current = adapter.__send__(
        :acquire_lease,
        thread_id:,
        namespace:,
        owner_id: "owner.current",
        ttl: 0.1
      )

      assert_operator current.fence, :>, stale.fence
      assert_raises(Tamoz::LeaseLostError) do
        adapter.__send__(:validate_lease, stale)
      end
      assert adapter.__send__(:validate_lease, current)
      adapter.__send__(:release_lease, current)
      adapter.close
    end
  end

  def test_successful_sibling_is_not_reexecuted_after_restart_and_resume
    Dir.mktmpdir("tamoz-sqlite-pending") do |directory|
      path = File.join(directory, "tamoz.db")
      successful_calls = 0
      definition = Tamoz.graph(name: "durable-pending", version: "1") do
        state :events, reduce: :append, default: []
        node(
          :succeed,
          implementation_name: "durable.pending.succeed",
          version: "1"
        ) do |_state, _context|
          successful_calls += 1
          {events: ["succeeded"]}
        end
        node(
          :pause,
          implementation_name: "durable.pending.pause",
          version: "1"
        ) do |_state, context|
          answer = Tamoz.interrupt({"question" => "continue?"}, context)
          {events: [answer]}
        end
        edge Tamoz::START, :succeed
        edge Tamoz::START, :pause
        edge :succeed, Tamoz::END
        edge :pause, Tamoz::END
      end
      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = definition.compile(checkpointer: adapter)
      paused = invoke_durable(
        app,
        thread: "thread.pending",
        request_id: "request.start",
        execution_id: "execution.pending",
        concurrency: :threads
      )
      assert paused.paused?
      assert_equal 1, successful_calls
      interrupt = paused.interrupts.first
      adapter.close

      reopened = Tamoz::SQLite::Adapter.new(path:)
      recovered = definition.compile(checkpointer: reopened)
      resumed = recovered.__send__(
        :resume_at,
        {interrupt.task_id => {interrupt.call_index => "continued"}},
        thread: "thread.pending",
        namespace: [],
        request_id: "request.resume",
        concurrency: :threads,
        context: nil
      )

      assert resumed.completed?
      assert_equal ["continued", "succeeded"], resumed.state.fetch(:events)
      assert_equal 1, successful_calls
      pending_count = raw_scalar(
        path,
        "SELECT COUNT(*) FROM tamoz_pending_activations WHERE consumed_by IS NULL"
      )
      assert_equal 0, pending_count
      reopened.close
    end
  end

  def test_payload_corruption_fails_before_graph_state_is_returned
    Dir.mktmpdir("tamoz-sqlite-corruption") do |directory|
      path = File.join(directory, "tamoz.db")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = counter_definition.compile(checkpointer: adapter)
      invoke_durable(
        app,
        thread: "thread.corrupt",
        request_id: "request.corrupt",
        execution_id: "execution.corrupt"
      )
      adapter.close

      database = SQLite3::Database.new(path)
      id, payload = database.get_first_row(
        "SELECT id, payload FROM tamoz_checkpoints ORDER BY sequence DESC LIMIT 1"
      )
      changed = payload.dup
      changed.setbyte(changed.bytesize / 2, changed.getbyte(changed.bytesize / 2) ^ 1)
      database.execute(
        "UPDATE tamoz_checkpoints SET payload = ? WHERE id = ?",
        [SQLite3::Blob.new(changed), id]
      )
      database.close

      reopened = Tamoz::SQLite::Adapter.new(path:)
      recovered = counter_definition.compile(checkpointer: reopened)
      assert_raises(Tamoz::CheckpointCorruptionError) do
        recovered.state(thread: "thread.corrupt")
      end
      reopened.close
    end
  end

  def test_prune_is_bounded_and_preserves_active_ancestry_and_request_links
    Dir.mktmpdir("tamoz-sqlite-prune") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      app = counter_definition.compile(checkpointer: adapter)
      app.durable_runner.deliver(
        {},
        thread: "thread.prune",
        request_id: "request.prune"
      )
      before = app.history(thread: "thread.prune", limit: 100)
      report = app.checkpointer.prune(
        thread_id: "thread.prune",
        namespace: [],
        keep: 1
      )

      assert_equal 0, report.deleted_count
      assert_equal before, app.history(thread: "thread.prune", limit: 100)
      assert_raises(Tamoz::ConfigurationError) do
        app.checkpointer.prune(
          thread_id: "thread.prune",
          namespace: [],
          keep: 0
        )
      end
      assert adapter.integrity_check.fetch("ok")
      adapter.close
    end
  end

  private

  def counter_definition
    Tamoz.graph(name: "durable-counter", version: "1") do
      state :count, default: 0
      node(
        :increment,
        implementation_name: "durable.counter.increment",
        version: "1"
      ) { |state, _context| {count: state.fetch(:count) + 1} }
      edge Tamoz::START, :increment
      edge :increment, Tamoz::END
    end
  end

  def invoke_durable(
    app,
    thread:,
    request_id:,
    execution_id:,
    concurrency: :inline
  )
    app.__send__(
      :invoke_at,
      {},
      thread:,
      namespace: [],
      request_id:,
      execution_id:,
      concurrency:,
      new_execution: false,
      context: nil
    )
  end

  def with_bound_store
    Dir.mktmpdir("tamoz-sqlite-store") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      store = counter_definition.compile(checkpointer: adapter).checkpointer
      yield adapter, store
      adapter.close
    end
  end

  def raw_scalar(path, sql)
    database = SQLite3::Database.new(path, readonly: true)
    database.get_first_value(sql)
  ensure
    database&.close
  end
end
