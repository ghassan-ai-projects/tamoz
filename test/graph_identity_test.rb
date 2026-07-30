# frozen_string_literal: true

require_relative "test_helper"

class GraphIdentityTest < Minitest::Test
  def test_activation_survives_new_base_while_attempt_identity_changes
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    planner_class = Tamoz::Graph.const_get(:Planner, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    first = append(
      checkpointer,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil
    )
    planner = planner_class.new(definition_digest: "sha256:#{"a" * 64}")
    first_task = planner.tasks(first).first
    attempts = {first_task.id => 1}.freeze
    paused = append(
      checkpointer,
      mode: :advance,
      frontier: first.frontier,
      expected_base_id: first.id,
      status: :paused,
      attempts:
    )
    second_task = planner.tasks(paused).first

    assert_equal first_task.id, second_task.id
    refute_equal first_task.attempt_id, second_task.attempt_id
    assert_equal 1, first_task.attempt
    assert_equal 2, second_task.attempt
    assert_equal first.id, first_task.base_checkpoint_id
    assert_equal paused.id, second_task.base_checkpoint_id
    assert_equal first.id, second_task.activation_checkpoint_id
  end

  def test_activation_identity_changes_for_execution_path_and_creation_checkpoint
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    planner_class = Tamoz::Graph.const_get(:Planner, false)
    planner = planner_class.new(definition_digest: "sha256:#{"b" * 64}")
    base = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1,
      activation_checkpoint_id: "checkpoint.1"
    )

    ids = [
      planner.activation_id("execution.1", base),
      planner.activation_id("execution.2", base),
      planner.activation_id("execution.1", base.with(path: %w[pull 1 other])),
      planner.activation_id(
        "execution.1",
        base.with(activation_checkpoint_id: "checkpoint.2")
      )
    ]
    assert_equal 4, ids.uniq.length
    assert ids.all? { |id| id.match?(/\Asha256:[0-9a-f]{64}\z/) }
  end

  def test_memory_checkpointer_assigns_strict_sequence_and_rejects_stale_base
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    first = append(
      checkpointer,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil
    )
    second = append(
      checkpointer,
      mode: :advance,
      frontier: [],
      expected_base_id: first.id,
      status: :completed
    )

    assert_equal [0, 1], [first.sequence, second.sequence]
    assert_equal first.id, second.parent_id
    assert_equal second, checkpointer.latest(thread_id: "thread.1")
    assert_equal [second, first], checkpointer.history(thread_id: "thread.1", limit: 10)
    assert_raises(Tamoz::CheckpointConflictError) do
      append(
        checkpointer,
        mode: :advance,
        frontier: [],
        expected_base_id: first.id
      )
    end
  end

  def test_fork_uses_historical_parent_but_appends_new_sequence
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    first = append(
      checkpointer,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil
    )
    second = append(
      checkpointer,
      mode: :advance,
      frontier: [],
      expected_base_id: first.id
    )
    forked = append(
      checkpointer,
      mode: :fork,
      frontier: [],
      expected_base_id: first.id,
      execution_id: "execution.fork"
    )

    assert_equal 2, forked.sequence
    assert_equal first.id, forked.parent_id
    refute_equal second.execution_id, forked.execution_id
    assert_equal forked, checkpointer.latest(thread_id: "thread.1")
  end

  def test_interrupt_cursor_is_explicit_positional_and_uses_throw
    cursor_class = Tamoz::Graph.const_get(:InterruptCursor, false)
    cursor = cursor_class.new(task_id: "task.1", resume_values: {0 => "approved"}.freeze)
    context = Tamoz::Context.new(
      run_id: "run.1",
      execution_id: "execution.1",
      request_id: "request.1",
      interrupts: cursor
    )

    assert_equal "approved", Tamoz.interrupt({"question" => "first"}, context)
    thrown = catch(:tamoz_interrupt) do
      Tamoz.interrupt({"question" => "second"}, context)
      flunk "interrupt did not throw"
    end
    assert_equal "task.1", thrown.fetch("task_id")
    assert_equal 1, thrown.fetch("call_index")
    assert_equal({"question" => "second"}, thrown.fetch("descriptor"))
  end

  def test_memory_checkpointer_defensively_freezes_checkpoint_metadata
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    mutable = {"nested" => ["value"]}
    checkpoint = append(
      checkpointer,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil,
      failure: [mutable]
    )
    mutable.fetch("nested") << "mutated"

    assert checkpoint.failure.frozen?
    assert checkpoint.failure.first.frozen?
    assert checkpoint.failure.first.fetch("nested").frozen?
    assert_equal ["value"], checkpoint.failure.first.fetch("nested")
    assert checkpoint.state_bytes.frozen?
  end

  def test_memory_checkpointer_bounds_retained_namespaces_and_checkpoints
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new(
      max_threads: 1,
      max_checkpoints_per_namespace: 1
    )
    first = append(
      checkpointer,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil,
      thread_id: "tenant:thread"
    )

    assert_raises(Tamoz::StateLimitError) do
      append(
        checkpointer,
        mode: :advance,
        frontier: [],
        expected_base_id: first.id,
        thread_id: "tenant:thread"
      )
    end
    assert_raises(Tamoz::StateLimitError) do
      append(
        checkpointer,
        mode: :start,
        frontier: [frontier],
        expected_base_id: nil,
        thread_id: "second:thread"
      )
    end
  end

  def test_interrupt_task_and_position_participate_in_checkpoint_identity
    frontier_class = Tamoz::Graph.const_get(:Frontier, false)
    frontier = frontier_class.new(
      node: :work,
      kind: :pull,
      path: %w[pull 1 work],
      logical_step: 1
    )
    first = append(
      Tamoz::Graph::MemoryCheckpointer.new,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil,
      status: :paused,
      interrupts: [
        Tamoz::Graph::Interrupt.new(
          task_id: "task.left",
          call_index: 0,
          descriptor: {"question" => "approve?"}
        )
      ]
    )
    second = append(
      Tamoz::Graph::MemoryCheckpointer.new,
      mode: :start,
      frontier: [frontier],
      expected_base_id: nil,
      status: :paused,
      interrupts: [
        Tamoz::Graph::Interrupt.new(
          task_id: "task.right",
          call_index: 0,
          descriptor: {"question" => "approve?"}
        )
      ]
    )

    refute_equal first.id, second.id
  end

  private

  def append(
    checkpointer,
    mode:,
    frontier:,
    expected_base_id:,
    status: :running,
    attempts: {},
    execution_id: "execution.1",
    failure: nil,
    thread_id: "thread.1",
    interrupts: []
  )
    state = {value: 0}.freeze
    checkpointer.append(
      thread_id:,
      namespace: [],
      expected_base_id:,
      mode:,
      attributes: {
        execution_id:,
        graph_name: "identity",
        graph_version: "1",
        definition_digest: "sha256:#{"c" * 64}",
        status:,
        logical_step: 1,
        state:,
        state_bytes: Tamoz::StateCodec.new.dump(state),
        frontier: frontier.freeze,
        pending: {}.freeze,
        interrupts: interrupts.freeze,
        resume_values: {}.freeze,
        attempts: attempts.freeze,
        failure:,
        total_tasks: 0
      }
    )
  end
end
