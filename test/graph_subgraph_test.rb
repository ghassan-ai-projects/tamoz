# frozen_string_literal: true

require_relative "test_helper"

class GraphSubgraphTest < Minitest::Test
  def test_parallel_subgraphs_share_parent_checkpointer_and_isolate_namespaces
    shared = Tamoz::Graph::MemoryCheckpointer.new
    decoy = Tamoz::Graph::MemoryCheckpointer.new
    child = child_graph.compile(checkpointer: decoy)
    parent = parallel_parent(child).compile(checkpointer: shared)

    result = parent.invoke(
      {},
      thread: "thread.nested",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads
    )

    diagnostics = result.errors.map do |error|
      [error.original.class, error.original.message, error.original.backtrace&.first]
    end
    assert result.completed?, diagnostics.inspect
    assert_equal ["child", "child"], result.state.fetch(:values)
    input_checkpoint = shared.history(
      thread_id: "thread.nested",
      namespace: [],
      limit: 10
    ).find { |checkpoint| checkpoint.sequence.zero? }
    tasks = parent.planner.tasks(input_checkpoint)
    namespaces = tasks.map do |task|
      [
        "subgraph",
        task.id.delete_prefix("sha256:"),
        "0",
        child.name,
        child.definition_digest.delete_prefix("sha256:")[0, 16]
      ]
    end

    assert_equal 2, namespaces.uniq.length
    namespaces.each do |namespace|
      history = shared.history(
        thread_id: "thread.nested",
        namespace:,
        limit: 10
      )
      assert_equal [1, 0], history.map(&:sequence)
      assert_equal :completed, history.first.status
      assert_equal ["child"], history.first.state.fetch(:values)
    end
    assert_empty decoy.history(
      thread_id: "thread.nested",
      namespace: namespaces.first,
      limit: 10
    )
  end

  def test_subgraph_interrupt_bubbles_and_resumes_by_parent_position
    calls = 0
    child = Tamoz.graph(name: "approval-child", version: "1") do
      state :answers, reduce: :append, default: []
      node(
        :approve,
        implementation_name: "approval.child",
        version: "1"
      ) do |_state, context|
        calls += 1
        answer = Tamoz.interrupt({"question" => "approve?"}, context)
        {answers: [answer]}
      end
      edge Tamoz::START, :approve
      edge :approve, Tamoz::END
    end.compile
    parent = Tamoz.graph(name: "approval-parent", version: "1") do
      state :answers, reduce: :append, default: []
      node(
        :child,
        child,
        implementation_name: "approval.parent.child",
        version: "1"
      )
      edge Tamoz::START, :child
      edge :child, Tamoz::END
    end.compile

    paused = parent.invoke(
      {},
      thread: "thread.approval",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    diagnostics = paused.errors.map do |error|
      [error.original.class, error.original.message, error.original.backtrace&.first]
    end
    assert paused.paused?, diagnostics.inspect
    assert_equal 1, calls
    descriptor = paused.interrupts.first.descriptor
    assert_equal "subgraph", descriptor.fetch("kind")
    assert_equal "approval-child", descriptor.fetch("graph")
    assert_equal "approve?", descriptor.dig("interrupts", 0, "descriptor", "question")
    child_namespace = descriptor.fetch("namespace")

    resumed = parent.resume(
      {
        paused.interrupts.first.task_id => {
          paused.interrupts.first.call_index => "approved"
        }
      },
      thread: "thread.approval",
      request_id: "request.2",
      concurrency: :inline
    )

    assert resumed.completed?
    assert_equal ["approved"], resumed.state.fetch(:answers)
    assert_equal 2, calls
    child_history = parent.checkpointer.history(
      thread_id: "thread.approval",
      namespace: child_namespace,
      limit: 10
    )
    assert_equal %i[completed paused running], child_history.map(&:status)
    assert_equal [2, 1, 0], child_history.map(&:sequence)
  end

  def test_compiled_subgraph_requires_an_explicit_parent_runtime
    child = child_graph.compile
    context = Tamoz::Context.new(
      run_id: "run.1",
      execution_id: "execution.1",
      request_id: "request.1"
    )

    error = assert_raises(Tamoz::ConfigurationError) { child.call({}, context) }

    assert_match(/parent graph task Context/, error.message)
  end

  def test_sequential_subgraph_calls_are_fresh_and_project_state_contracts
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    child = Tamoz.graph(name: "projected-child", version: "1") do
      state :values, reduce: :append, default: []
      state :remaining, managed: Tamoz::Managed::RemainingSteps
      node(
        :work,
        implementation_name: "projected.child.work",
        version: "1"
      ) { |state, _context| {values: ["child@#{state[:values].length}"]} }
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end.compile
    parent = Tamoz.graph(name: "projected-parent", version: "1") do
      state :values, reduce: :append, default: []
      state :parent_only, default: "retained"
      node(
        :twice,
        implementation_name: "projected.parent.twice",
        version: "1"
      ) do |state, context|
        first = child.call(state, context)
        second = child.call(state, context)
        {values: first.fetch(:values) + second.fetch(:values)}
      end
      edge Tamoz::START, :twice
      edge :twice, Tamoz::END
    end.compile(checkpointer:)

    result = parent.invoke(
      {},
      thread: "tenant:thread:sequential",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )

    assert result.completed?
    assert_equal ["child@0", "child@0"], result.state.fetch(:values)
    assert_equal "retained", result.state.fetch(:parent_only)
    input_checkpoint = checkpointer.history(
      thread_id: "tenant:thread:sequential",
      namespace: [],
      limit: 10
    ).last
    task = parent.planner.tasks(input_checkpoint).first
    namespaces = [0, 1].map do |index|
      [
        "subgraph",
        task.id.delete_prefix("sha256:"),
        index.to_s,
        child.name,
        child.definition_digest.delete_prefix("sha256:")[0, 16]
      ]
    end
    assert namespaces.all? { |namespace|
      checkpointer.latest(
        thread_id: "tenant:thread:sequential",
        namespace:
      )&.status == :completed
    }
  end

  private

  def child_graph
    Tamoz.graph(name: "parallel-child", version: "1") do
      state :values, reduce: :append, default: []
      node(
        :work,
        implementation_name: "parallel.child.work",
        version: "1"
      ) { |_state, _context| {values: ["child"]} }
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end
  end

  def parallel_parent(child)
    Tamoz.graph(name: "parallel-parent", version: "1") do
      state :values, reduce: :append, default: []
      node(
        :left,
        child,
        implementation_name: "parallel.parent.left",
        version: "1"
      )
      node(
        :right,
        child,
        implementation_name: "parallel.parent.right",
        version: "1"
      )
      edge Tamoz::START, :left
      edge Tamoz::START, :right
      edge :left, Tamoz::END
      edge :right, Tamoz::END
    end
  end
end
