# frozen_string_literal: true

require_relative "test_helper"

class GraphExecutionTest < Minitest::Test
  def test_supersteps_share_one_snapshot_and_fan_in_runs_once
    observations = Queue.new
    definition = Tamoz.graph(name: "barrier", version: "1") do
      state :events, reduce: :append, default: []
      state :observed, default: []
      node(
        :left,
        implementation_name: "barrier.left",
        version: "1"
      ) { |state, _context| {events: ["left:#{state[:events].length}"]} }
      node(
        :right,
        implementation_name: "barrier.right",
        version: "1"
      ) { |state, _context| {events: ["right:#{state[:events].length}"]} }
      node(
        :join,
        implementation_name: "barrier.join",
        version: "1"
      ) do |state, _context|
        observations << state[:events]
        {observed: state[:events]}
      end
      edge Tamoz::START, :left
      edge Tamoz::START, :right
      edge :left, :join
      edge :right, :join
      edge :join, Tamoz::END
    end

    result = definition.compile.invoke(
      {},
      thread: "thread.barrier",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads
    )

    assert result.completed?
    assert_equal ["left:0", "right:0"], result.state.fetch(:events)
    assert_equal ["left:0", "right:0"], result.state.fetch(:observed)
    assert_equal ["left:0", "right:0"], observations.pop
    assert observations.empty?, "fan-in node ran more than once"
  end

  def test_inline_and_threads_commit_byte_identical_histories
    definition = deterministic_definition
    inline = definition.compile
    threaded = definition.compile

    inline_result = inline.invoke(
      {},
      thread: "thread.same",
      request_id: "request.same",
      execution_id: "execution.same",
      concurrency: :inline
    )
    threaded_result = threaded.invoke(
      {},
      thread: "thread.same",
      request_id: "request.same",
      execution_id: "execution.same",
      concurrency: :threads
    )

    assert_equal inline_result.state, threaded_result.state
    assert_equal(
      inline.history(thread: "thread.same").map { |entry| [entry.checkpoint_id, entry.state] },
      threaded.history(thread: "thread.same").map { |entry| [entry.checkpoint_id, entry.state] }
    )
  end

  def test_branch_observes_candidate_state
    visited = []
    definition = Tamoz.graph(name: "branch-candidate", version: "1") do
      state :decision, default: "stop"
      state :visited, reduce: :append, default: []
      node(
        :decide,
        implementation_name: "branch.decide",
        version: "1"
      ) { |_state, _context| {decision: "go"} }
      node(
        :go,
        implementation_name: "branch.go",
        version: "1"
      ) do |_state, _context|
        visited << "go"
        {visited: ["go"]}
      end
      edge Tamoz::START, :decide
      branch :decide, version: "1", targets: [:go, Tamoz::END] do |state|
        state[:decision] == "go" ? :go : Tamoz::END
      end
      edge :go, Tamoz::END
    end

    result = definition.compile.invoke(
      {},
      thread: "thread.branch",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    assert_equal ["go"], result.state.fetch(:visited)
    assert_equal ["go"], visited
  end

  def test_dynamic_send_fanout_is_keyed_and_ordered
    definition = Tamoz.graph(name: "fanout", version: "1") do
      state :item, default: ""
      state :results, reduce: :append, default: []
      node(
        :dispatch,
        implementation_name: "fanout.dispatch",
        version: "1",
        routing: :dynamic,
        routes: [:worker]
      ) do |_state, _context|
        Tamoz::Command.new(
          goto: [
            Tamoz.send_to(:worker, {"item" => "b"}, key: "b"),
            Tamoz.send_to(:worker, {"item" => "a"}, key: "a")
          ]
        )
      end
      node(
        :worker,
        implementation_name: "fanout.worker",
        version: "1"
      ) { |input, _context| {results: [input.fetch(:item)]} }
      edge Tamoz::START, :dispatch
      edge :worker, Tamoz::END
    end

    result = definition.compile.invoke(
      {},
      thread: "thread.fanout",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads
    )

    assert_equal ["a", "b"], result.state.fetch(:results)
  end

  def test_send_keys_cannot_collide_with_positional_keys
    app = Tamoz.graph(name: "fanout-key-collision", version: "1") do
      state :results, reduce: :append, default: []
      node(
        :dispatch,
        implementation_name: "fanout.collision.dispatch",
        version: "1",
        routing: :dynamic,
        routes: [:worker]
      ) do |_state, _context|
        Tamoz::Command.new(
          goto: [
            Tamoz.send_to(:worker, {}, key: "1"),
            Tamoz.send_to(:worker, {})
          ]
        )
      end
      node(
        :worker,
        implementation_name: "fanout.collision.worker",
        version: "1"
      ) { |_state, _context| {results: ["unexpected"]} }
      edge Tamoz::START, :dispatch
      edge :worker, Tamoz::END
    end.compile

    error = assert_raises(Tamoz::InvalidUpdateError) do
      app.invoke(
        {},
        thread: "thread.collision",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :inline
      )
    end

    assert_match(/colliding Send key/, error.message)
    assert_equal 0, app.history(thread: "thread.collision").last.sequence
  end

  def test_static_and_dynamic_routes_are_additive_only_when_declared
    definition = Tamoz.graph(name: "additive", version: "1") do
      state :visited, reduce: :append, default: []
      node(
        :dispatch,
        implementation_name: "additive.dispatch",
        version: "1",
        routing: :additive,
        routes: [:dynamic]
      ) { |_state, _context| Tamoz::Command.new(goto: :dynamic) }
      node(
        :static,
        implementation_name: "additive.static",
        version: "1"
      ) { |_state, _context| {visited: ["static"]} }
      node(
        :dynamic,
        implementation_name: "additive.dynamic",
        version: "1"
      ) { |_state, _context| {visited: ["dynamic"]} }
      edge Tamoz::START, :dispatch
      edge :dispatch, :static
      edge :static, Tamoz::END
      edge :dynamic, Tamoz::END
    end

    result = definition.compile.invoke(
      {},
      thread: "thread.additive",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    assert_equal ["dynamic", "static"], result.state.fetch(:visited)

    rejected = Tamoz.graph(name: "rejected-route", version: "1") do
      state :value
      node(
        :dispatch,
        implementation_name: "rejected.dispatch",
        version: "1",
        routing: :dynamic,
        routes: [Tamoz::END]
      ) { |_state, _context| Tamoz::Command.new(goto: :missing) }
      edge Tamoz::START, :dispatch
    end.compile
    assert_raises(Tamoz::InvalidUpdateError) do
      rejected.invoke(
        {},
        thread: "thread.rejected",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :inline
      )
    end
    assert_equal 1, rejected.history(thread: "thread.rejected").length
  end

  def test_conflicting_last_value_writes_fail_before_state_commit
    definition = Tamoz.graph(name: "conflict", version: "1") do
      state :status, default: "initial"
      node(
        :left,
        implementation_name: "conflict.left",
        version: "1"
      ) { |_state, _context| {status: "left"} }
      node(
        :right,
        implementation_name: "conflict.right",
        version: "1"
      ) { |_state, _context| {status: "right"} }
      edge Tamoz::START, :left
      edge Tamoz::START, :right
      edge :left, Tamoz::END
      edge :right, Tamoz::END
    end
    app = definition.compile

    error = assert_raises(Tamoz::InvalidUpdateError) do
      app.invoke(
        {},
        thread: "thread.conflict",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :threads
      )
    end
    assert_includes error.message, "sha256:"
    history = app.history(thread: "thread.conflict")
    assert_equal 1, history.length
    assert_equal "initial", history.first.state.fetch(:status)
  end

  def test_failure_retry_reuses_successful_sibling
    calls = Hash.new(0)
    definition = Tamoz.graph(name: "retry", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :stable,
        implementation_name: "retry.stable",
        version: "1"
      ) do |_state, _context|
        calls[:stable] += 1
        {events: ["stable"]}
      end
      node(
        :flaky,
        implementation_name: "retry.flaky",
        version: "1"
      ) do |_state, _context|
        calls[:flaky] += 1
        raise "first attempt" if calls[:flaky] == 1

        {events: ["flaky"]}
      end
      edge Tamoz::START, :stable
      edge Tamoz::START, :flaky
      edge :stable, Tamoz::END
      edge :flaky, Tamoz::END
    end
    app = definition.compile
    failed = app.invoke(
      {},
      thread: "thread.retry",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads
    )

    assert failed.failed?
    assert_equal({events: []}, failed.state)
    assert_instance_of Tamoz::NodeError, failed.errors.first
    assert_equal "flaky", failed.errors.first.node
    retried = app.retry_failed(
      thread: "thread.retry",
      request_id: "request.2",
      concurrency: :threads
    )

    assert retried.completed?
    assert_equal ["flaky", "stable"], retried.state.fetch(:events)
    assert_equal({stable: 1, flaky: 2}, calls)
  end

  def test_invalid_invocation_configuration_never_creates_a_checkpoint
    app = deterministic_definition.compile

    assert_raises(Tamoz::ConfigurationError) do
      app.invoke(
        {},
        thread: "thread.invalid.execution",
        request_id: "request.1",
        execution_id: "bad\nexecution",
        concurrency: :inline
      )
    end
    assert_raises(Tamoz::ConfigurationError) do
      app.invoke(
        {},
        thread: "thread.invalid.concurrency",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :unknown
      )
    end
    assert_raises(Tamoz::ConfigurationError) do
      app.invoke(
        {},
        thread: "thread.invalid.turn",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :inline,
        new_execution: "yes"
      )
    end

    %w[
      thread.invalid.execution
      thread.invalid.concurrency
      thread.invalid.turn
    ].each do |thread|
      assert_nil app.checkpointer.latest(thread_id: thread)
    end
  end

  def test_anonymous_exception_class_never_enters_checkpoint_identity
    error_class = Class.new(StandardError)
    definition = Tamoz.graph(name: "anonymous-error", version: "1") do
      state :value
      node(
        :fail,
        implementation_name: "anonymous.error.fail",
        version: "1"
      ) { |_state, _context| raise error_class, "unstable detail" }
      edge Tamoz::START, :fail
      edge :fail, Tamoz::END
    end
    first = definition.compile
    second = definition.compile
    identity = {
      thread: "thread.anonymous",
      request_id: "request.1",
      execution_id: "execution.1"
    }

    first.invoke({}, **identity, concurrency: :inline)
    second.invoke({}, **identity, concurrency: :threads)
    first_failure = first.checkpointer.latest(
      thread_id: identity.fetch(:thread)
    )
    second_failure = second.checkpointer.latest(
      thread_id: identity.fetch(:thread)
    )

    assert_equal "AnonymousError", first_failure.failure.first.fetch("error_class")
    assert_equal first_failure.id, second_failure.id
  end

  def test_stuck_worker_circuit_survives_barriers_and_runs
    entered = Queue.new
    release = Queue.new
    calls = 0
    pool_size = Tamoz.configuration.pool_size
    definition = Tamoz.graph(name: "persistent-circuit", version: "1") do
      state :value
      pool_size.times do |index|
        node(
          :"stuck_#{index}",
          implementation_name: "persistent.circuit.stuck-#{index}",
          version: "1"
        ) do |_state, _context|
          calls += 1
          entered << true
          release.pop
          nil
        end
        edge Tamoz::START, :"stuck_#{index}"
        edge :"stuck_#{index}", Tamoz::END
      end
    end
    app = definition.compile
    cancellation = Tamoz::CancellationToken.new
    context = Tamoz::Context.new(
      run_id: "run.1",
      execution_id: "execution.1",
      request_id: "request.1",
      thread_id: "thread.circuit.1",
      cancellation:
    )
    result_queue = Queue.new
    runner = Thread.new do
      result_queue << app.invoke(
        {},
        thread: "thread.circuit.1",
        request_id: "request.1",
        execution_id: "execution.1",
        concurrency: :threads,
        context:
      )
    end
    pool_size.times { entered.pop }
    cancellation.cancel!("test_circuit")
    runner.join(2)
    result = result_queue.pop
    pool_size.times { release << true }

    assert result.cancelled?
    assert_equal pool_size, calls
    error = assert_raises(Tamoz::PoolCircuitOpenError) do
      app.invoke(
        {},
        thread: "thread.circuit.2",
        request_id: "request.2",
        execution_id: "execution.2",
        concurrency: :threads
      )
    end
    assert_match(/circuit is open/, error.message)
    assert_equal pool_size, calls
  ensure
    pool_size&.times { release << true } if release
    cancellation&.cancel!("test_cleanup")
    runner&.join(2)
  end

  private

  def deterministic_definition
    Tamoz.graph(name: "deterministic", version: "1") do
      state :values, reduce: :append, default: []
      node(
        :left,
        implementation_name: "deterministic.left",
        version: "1"
      ) do |_state, _context|
        sleep(0.0002)
        {values: ["left"]}
      end
      node(
        :right,
        implementation_name: "deterministic.right",
        version: "1"
      ) { |_state, _context| {values: ["right"]} }
      edge Tamoz::START, :left
      edge Tamoz::START, :right
      edge :left, Tamoz::END
      edge :right, Tamoz::END
    end
  end
end
