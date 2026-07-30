# frozen_string_literal: true

require_relative "test_helper"

class GraphHistoryTest < Minitest::Test
  def test_historical_update_uses_reducer_appends_fork_and_can_continue
    app = history_definition.compile
    completed = app.invoke(
      {},
      thread: "thread.history",
      request_id: "request.1",
      execution_id: "execution.original",
      concurrency: :inline
    )
    original_history = app.history(thread: "thread.history")
    input = original_history.last

    forked = app.update_state(
      {events: ["manual"]},
      thread: "thread.history",
      checkpoint_id: input.checkpoint_id,
      execution_id: "execution.fork"
    )

    assert_equal 2, forked.sequence
    assert_equal "execution.fork", forked.execution_id
    assert_equal ["manual"], forked.state.fetch(:events)
    assert_equal(
      ["node"],
      app.state(
        thread: "thread.history",
        checkpoint_id: completed.snapshot.checkpoint_id
      ).state.fetch(:events)
    )

    continued = app.continue(
      thread: "thread.history",
      request_id: "request.2",
      concurrency: :inline
    )
    assert continued.completed?
    assert_equal ["manual", "node"], continued.state.fetch(:events)
    assert_equal [3, 2, 1, 0], app.history(thread: "thread.history").map(&:sequence)
  end

  def test_latest_update_preserves_execution_and_runs_reducer
    app = history_definition.compile
    completed = app.invoke(
      {},
      thread: "thread.latest",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    edited = app.update_state({events: ["manual"]}, thread: "thread.latest")

    assert_equal completed.snapshot.execution_id, edited.execution_id
    assert_equal ["node", "manual"], edited.state.fetch(:events)
    assert_equal :completed, edited.status
  end

  def test_new_execution_starts_from_defaults_and_appends_after_latest
    app = history_definition.compile
    first = app.invoke(
      {},
      thread: "thread.turns",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    second = app.invoke(
      {events: ["new-input"]},
      thread: "thread.turns",
      request_id: "request.2",
      execution_id: "execution.2",
      concurrency: :inline,
      new_execution: true
    )

    assert_equal ["node"], first.state.fetch(:events)
    assert_equal ["new-input", "node"], second.state.fetch(:events)
    assert_equal "execution.2", second.snapshot.execution_id
    assert_equal [3, 2, 1, 0], app.history(thread: "thread.turns").map(&:sequence)
  end

  def test_graph_identity_is_checked_before_state_access_or_user_code
    calls = 0
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    first = Tamoz.graph(name: "compatible", version: "1") do
      state :value, default: 0
      node(
        :step,
        implementation_name: "compatible.step",
        version: "1"
      ) do |_state, _context|
        calls += 1
        {value: 1}
      end
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end.compile(checkpointer:)
    first.invoke(
      {},
      thread: "thread.compatible",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    incompatible = Tamoz.graph(name: "compatible", version: "2") do
      state :value, default: 0
      node(
        :step,
        implementation_name: "compatible.step",
        version: "2"
      ) { |_state, _context| {value: 2} }
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end.compile(checkpointer:)

    assert_raises(Tamoz::CheckpointVersionError) do
      incompatible.state(thread: "thread.compatible")
    end
    assert_raises(Tamoz::CheckpointVersionError) do
      incompatible.continue(
        thread: "thread.compatible",
        request_id: "request.2",
        concurrency: :inline
      )
    end
    assert_equal 1, calls
  end

  def test_step_limit_stops_before_an_excess_barrier
    limits = Tamoz::Graph::Limits.new(max_steps: 2)
    app = Tamoz.graph(name: "bounded-cycle", version: "1") do
      state :count, reduce: :max, default: 0
      state :remaining, managed: Tamoz::Managed::RemainingSteps
      node(
        :loop,
        implementation_name: "bounded.loop",
        version: "1"
      ) { |state, _context| {count: state[:count] + 1} }
      edge Tamoz::START, :loop
      branch :loop, version: "1", targets: [:loop, Tamoz::END] do |_state|
        :loop
      end
    end.compile(limits:)

    assert_raises(Tamoz::RecursionLimitError) do
      app.invoke(
        {},
        thread: "thread.cycle",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :inline
      )
    end
    latest = app.state(thread: "thread.cycle")
    assert_equal 2, latest.state.fetch(:count)
    assert_equal 0, latest.state.fetch(:remaining)
    assert_equal 2, latest.sequence
  end

  def test_history_reads_are_bounded
    limits = Tamoz::Graph::Limits.new(history_limit: 2)
    app = history_definition.compile(limits:)
    app.invoke(
      {},
      thread: "thread.limit",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    assert_equal 2, app.history(thread: "thread.limit").length
    assert_raises(Tamoz::StateLimitError) do
      app.history(thread: "thread.limit", limit: 3)
    end
  end

  def test_snapshot_exposes_safe_scheduler_projection_without_pending_writes
    app = history_definition.compile
    result = app.invoke(
      {},
      thread: "thread.projection",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    history = app.history(thread: "thread.projection")
    input = history.last

    assert_equal [:step], input.next
    assert_equal [], input.pending_task_ids
    assert_equal 0, input.logical_step
    assert_nil input.parent_checkpoint_id
    assert_equal input.checkpoint_id, result.snapshot.parent_checkpoint_id
    refute_respond_to result.snapshot, :pending
    assert result.snapshot.frozen?
  end

  private

  def history_definition
    Tamoz.graph(name: "history", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :step,
        implementation_name: "history.step",
        version: "1"
      ) { |_state, _context| {events: ["node"]} }
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end
  end
end
