# frozen_string_literal: true

require_relative "test_helper"

class GraphStreamTest < Minitest::Test
  def test_stream_projects_events_without_changing_the_result
    app = linear_graph.compile
    stream = app.stream(
      {events: ["input"]},
      thread: "thread.stream",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline,
      mode: %i[tasks updates checkpoints],
      capacity: 2
    )

    parts = stream.to_a

    assert_equal :completed, stream.result.status
    assert_equal ["input", "node"], stream.result.state.fetch(:events)
    assert_equal :run_start, parts.first.type
    assert_equal :run_end, parts.last.type
    assert_includes parts.map(&:type), :task_start
    assert_includes parts.map(&:type), :task_end
    assert_includes parts.map(&:type), :node_update
    assert_includes parts.map(&:type), :checkpoint
    assert parts.all? { |part| part.run_id && part.data.frozen? }
  end

  def test_requesting_result_drains_the_bounded_event_queue
    app = linear_graph.compile
    stream = app.stream(
      {},
      thread: "thread.result",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline,
      capacity: 1
    )

    result = stream.result

    assert result.completed?
    assert_equal ["node"], result.state.fetch(:events)
    assert_raises(Tamoz::ConfigurationError) { stream.to_a }
  end

  def test_mode_is_only_an_event_projection
    streamed = linear_graph.compile
    regular = linear_graph.compile

    parts = streamed.stream(
      {},
      thread: "thread.projected",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline,
      mode: :updates,
      capacity: 1
    ).each.to_a
    expected = regular.invoke(
      {},
      thread: "thread.regular",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    assert_equal %i[run_start node_update run_end], parts.map(&:type)
    assert_equal expected.state, streamed.state(thread: "thread.projected").state
  end

  def test_early_consumer_exit_cancels_and_prevents_a_late_commit
    entered = Queue.new
    app = Tamoz.graph(name: "cancel-stream", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :first,
        implementation_name: "cancel.first",
        version: "1"
      ) { |_state, _context| {events: ["first"]} }
      node(
        :second,
        implementation_name: "cancel.second",
        version: "1"
      ) do |_state, context|
        entered << true
        loop do
          context.check!
          sleep(0.001)
        end
      end
      edge Tamoz::START, :first
      edge :first, :second
      edge :second, Tamoz::END
    end.compile
    stream = app.stream(
      {},
      thread: "thread.cancel",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads,
      mode: %i[tasks updates checkpoints],
      capacity: 1,
      join_grace: 1.0
    )

    stream.each do |part|
      break if part.type == :task_start && part.data.fetch("node") == "second"
    end
    entered.pop

    snapshot = app.state(thread: "thread.cancel")
    assert_equal ["first"], snapshot.state.fetch(:events)
    assert_equal :running, snapshot.status
    assert_equal 1, snapshot.sequence
    assert stream.sink.cancellation.cancelled?
    refute Thread.list.any? { |thread| thread.name == "tamoz-graph-stream" && thread.alive? }
  ensure
    stream&.close
  end

  def test_stream_surfaces_safe_error_event_then_reraises
    app = linear_graph.compile
    app.invoke(
      {},
      thread: "thread.conflict",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    stream = app.stream(
      {},
      thread: "thread.conflict",
      request_id: "request.2",
      execution_id: "execution.2",
      concurrency: :inline,
      capacity: 2
    )
    parts = []

    # The invoke-thread-exists precondition (compiled.rb:470) is a stale-request
    # condition (DR-4 C2): it raises StaleRequestError, still a CheckpointError with a
    # safe message that never discloses the caller hint.
    error = assert_raises(Tamoz::StaleRequestError) do
      stream.each { |part| parts << part }
    end

    assert_equal "stale_request", error.category
    assert_equal %i[run_start error], parts.map(&:type)
    assert_equal(
      "The durable request is stale.",
      parts.last.data.fetch("safe_message")
    )
    refute parts.last.data.to_s.include?("use resume")
  end

  def test_node_failure_emits_only_safe_error_metadata
    app = Tamoz.graph(name: "stream-node-failure", version: "1") do
      state :value
      node(
        :fail,
        implementation_name: "stream.failure.node",
        version: "1"
      ) { |_state, _context| raise "secret failure details" }
      edge Tamoz::START, :fail
      edge :fail, Tamoz::END
    end.compile
    stream = app.stream(
      {},
      thread: "thread.node.failure",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline,
      capacity: 2
    )

    parts = stream.each.to_a
    error_part = parts.find { |part| part.type == :error }

    assert stream.result.failed?
    refute_nil error_part
    assert_equal "node", error_part.data.fetch("category")
    assert_equal "A workflow step failed.", error_part.data.fetch("safe_message")
    refute_includes error_part.data.to_s, "secret failure details"
  end

  def test_stopping_at_every_event_boundary_never_commits_late_state
    reference_app = two_step_graph.compile
    reference_stream = reference_app.stream(
      {},
      thread: "thread.reference",
      request_id: "request.1",
      execution_id: "execution.reference",
      concurrency: :threads,
      capacity: 1
    )
    reference_parts = reference_stream.each.to_a
    reference_states = reference_app.history(thread: "thread.reference").map(&:state)

    (1...reference_parts.length).each do |stop_after|
      app = two_step_graph.compile
      stream = app.stream(
        {},
        thread: "thread.stop.#{stop_after}",
        request_id: "request.1",
        execution_id: "execution.stop.#{stop_after}",
        concurrency: :threads,
        capacity: 1,
        join_grace: 1.0
      )
      consumed = 0
      stream.each do |_part|
        consumed += 1
        break if consumed == stop_after
      end
      snapshot = app.state(thread: "thread.stop.#{stop_after}")
      stable_id = snapshot.checkpoint_id

      assert_includes reference_states, snapshot.state, "event index #{stop_after}"
      sleep(0.002)
      assert_equal stable_id,
                   app.state(thread: "thread.stop.#{stop_after}").checkpoint_id,
                   "late commit at event index #{stop_after}"
      refute Thread.list.any? { |thread|
        thread.name == "tamoz-graph-stream" && thread.alive?
      }
    ensure
      stream&.close
    end
  end

  private

  def linear_graph
    Tamoz.graph(name: "stream-linear", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :step,
        implementation_name: "stream.step",
        version: "1"
      ) { |_state, _context| {events: ["node"]} }
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end
  end

  def two_step_graph
    Tamoz.graph(name: "stream-two-step", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :first,
        implementation_name: "stream.two.first",
        version: "1"
      ) { |_state, _context| {events: ["first"]} }
      node(
        :second,
        implementation_name: "stream.two.second",
        version: "1"
      ) { |_state, _context| {events: ["second"]} }
      edge Tamoz::START, :first
      edge :first, :second
      edge :second, Tamoz::END
    end
  end
end
