# frozen_string_literal: true

require_relative "test_helper"

class GraphInterruptTest < Minitest::Test
  def test_three_interrupts_restart_from_top_and_reuse_successful_sibling_inline
    exercise_sequential_interrupts(:inline)
  end

  def test_three_interrupts_restart_from_top_and_reuse_successful_sibling_threads
    exercise_sequential_interrupts(:threads)
  end

  def test_parallel_interrupts_are_keyed_by_task_and_call_index
    definition = Tamoz.graph(name: "parallel-interrupts", version: "1") do
      state :answers, reduce: :merge, default: {}
      node(
        :left,
        implementation_name: "interrupt.left",
        version: "1"
      ) do |_state, context|
        answer = Tamoz.interrupt({"side" => "left"}, context)
        {answers: {"left" => answer}}
      end
      node(
        :right,
        implementation_name: "interrupt.right",
        version: "1"
      ) do |_state, context|
        answer = Tamoz.interrupt({"side" => "right"}, context)
        {answers: {"right" => answer}}
      end
      edge Tamoz::START, :left
      edge Tamoz::START, :right
      edge :left, Tamoz::END
      edge :right, Tamoz::END
    end
    app = definition.compile
    paused = app.invoke(
      {},
      thread: "thread.parallel",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :threads
    )

    assert paused.paused?
    assert_equal 2, paused.interrupts.length
    assert_equal [0], paused.interrupts.map(&:call_index).uniq
    answers = paused.interrupts.to_h do |interrupt|
      side = interrupt.descriptor.fetch("side")
      [interrupt.task_id, {0 => "answer-#{side}"}]
    end
    completed = app.resume(
      answers,
      thread: "thread.parallel",
      request_id: "request.2",
      concurrency: :threads
    )

    assert completed.completed?
    assert_equal(
      {"left" => "answer-left", "right" => "answer-right"},
      completed.state.fetch(:answers)
    )
  end

  def test_unknown_resume_answer_fails_before_user_code
    calls = 0
    definition = Tamoz.graph(name: "resume-validation", version: "1") do
      state :answer
      node(
        :ask,
        implementation_name: "resume.ask",
        version: "1"
      ) do |_state, context|
        calls += 1
        {answer: Tamoz.interrupt({"question" => "approve"}, context)}
      end
      edge Tamoz::START, :ask
      edge :ask, Tamoz::END
    end
    app = definition.compile
    paused = app.invoke(
      {},
      thread: "thread.validation",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    assert_equal 1, calls

    assert_raises(Tamoz::InvalidUpdateError) do
      app.resume(
        {"unknown-task" => {0 => "answer"}},
        thread: "thread.validation",
        request_id: "request.2",
        concurrency: :inline
      )
    end
    assert_equal 1, calls
    assert_equal paused.snapshot, app.state(thread: "thread.validation")
  end

  def test_stale_attempt_result_is_rejected_before_barrier_use
    definition = sequential_definition(Hash.new(0))
    app = definition.compile
    paused = app.invoke(
      {},
      thread: "thread.stale",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    )
    checkpoint = app.checkpointer.latest(thread_id: "thread.stale")
    task = app.planner.tasks(checkpoint).find { |entry| entry.id == paused.interrupts.first.task_id }
    outcome_class = Tamoz::Graph.const_get(:Outcome, false)
    forged = outcome_class.new(
      task_id: task.id,
      attempt_id: "sha256:#{"0" * 64}",
      base_checkpoint_id: checkpoint.id,
      node: task.node,
      path: task.path,
      update: {}.freeze,
      goto: nil
    )
    executor_class = Tamoz::Graph.const_get(:Executor, false)
    executor = executor_class.new(app)

    assert_raises(Tamoz::CheckpointConflictError) do
      executor.__send__(
        :validate_outcome!,
        task,
        forged,
        checkpoint,
        pending: false
      )
    end
  end

  private

  def exercise_sequential_interrupts(concurrency)
    calls = Hash.new(0)
    app = sequential_definition(calls).compile
    thread = "thread.#{concurrency}"
    result = app.invoke(
      {},
      thread:,
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency:
    )
    assert result.paused?
    task_id = result.interrupts.first.task_id
    assert_equal 0, result.interrupts.first.call_index

    checkpoints = app.checkpointer.history(thread_id: thread, limit: 10).reverse
    attempts = [app.planner.tasks(checkpoints.first).find { |task| task.id == task_id }]
    3.times do |index|
      pending_checkpoint = app.checkpointer.latest(thread_id: thread)
      attempts << app.planner.tasks(pending_checkpoint).find { |task| task.id == task_id }
      result = app.resume(
        {task_id => {index => "answer-#{index}"}},
        thread:,
        request_id: "request.#{index + 2}",
        concurrency:
      )
      if index < 2
        assert result.paused?
        assert_equal index + 1, result.interrupts.first.call_index
      end
    end

    assert result.completed?
    assert_equal %w[answer-0 answer-1 answer-2], result.state.fetch(:answers)
    assert_equal ["sibling"], result.state.fetch(:events)
    assert_equal 4, calls.fetch(:approval)
    assert_equal 1, calls.fetch(:sibling)
    assert_equal 0, calls.fetch(:rescued, 0)
    assert_equal 1, attempts.map(&:id).uniq.length
    assert_equal 4, attempts.map(&:attempt_id).uniq.length
    assert_equal [1, 2, 3, 4], attempts.map(&:attempt)
    assert_equal 4, attempts.map(&:base_checkpoint_id).uniq.length
  end

  def sequential_definition(calls)
    Tamoz.graph(name: "sequential-interrupts", version: "1") do
      state :answers, default: []
      state :events, reduce: :append, default: []
      node(
        :approval,
        implementation_name: "interrupt.approval",
        version: "1"
      ) do |_state, context|
        calls[:approval] += 1
        begin
          answers = 3.times.map do |index|
            Tamoz.interrupt({"question" => index}, context)
          end
          {answers:}
        rescue StandardError
          calls[:rescued] += 1
          raise
        end
      end
      node(
        :sibling,
        implementation_name: "interrupt.sibling",
        version: "1"
      ) do |_state, _context|
        calls[:sibling] += 1
        {events: ["sibling"]}
      end
      edge Tamoz::START, :approval
      edge Tamoz::START, :sibling
      edge :approval, Tamoz::END
      edge :sibling, Tamoz::END
    end
  end
end
