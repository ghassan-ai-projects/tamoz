# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/thread_barrier'

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one parent graph and its fan-out, declared inline

# `Compiled#call_many`: several children of one parent node run at once, each stored under its own input's call index.
class GraphSubgraphFanoutTest < Minitest::Test
  def test_call_many_runs_children_at_once_and_stores_each_under_its_input_order
    checkpointer = Tamoz::Graph::MemoryCheckpointer.new
    arrived = Queue.new
    barrier = ThreadBarrier.new(3)
    child = Tamoz.graph(name: 'fanout-child', version: '1') do
      state :label, default: ''
      state :values, reduce: :append, default: []
      node(:work, implementation_name: 'fanout.child.work', version: '1') do |state, _context|
        arrived << state[:label]
        barrier.wait
        { values: ["done:#{state[:label]}"] }
      end
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end.compile
    parent = Tamoz.graph(name: 'fanout-parent', version: '1') do
      state :values, reduce: :append, default: []
      node(:fan, implementation_name: 'fanout.parent.fan', version: '1') do |_state, context|
        outputs = child.call_many(%w[a b c].map { |label| { label: } }, context)
        { values: outputs.flat_map { |output| output.fetch(:values) } }
      end
      edge Tamoz::START, :fan
      edge :fan, Tamoz::END
    end.compile(checkpointer:)

    result = parent.invoke({}, thread: 'thread:fanout', request_id: 'r1', execution_id: 'e1', concurrency: :inline)

    assert_predicate result, :completed?, result.errors.map(&:message).inspect
    assert_equal %w[done:a done:b done:c], result.state.fetch(:values)
    task = parent.planner.tasks(checkpointer.history(thread_id: 'thread:fanout', namespace: [], limit: 10).last).first
    stored = [0, 1, 2].map do |index|
      namespace = ['subgraph', task.id.delete_prefix('sha256:'), index.to_s, child.name,
                   child.definition_digest.delete_prefix('sha256:')[0, 16]]
      checkpointer.latest(thread_id: 'thread:fanout', namespace:).state.fetch(:label)
    end

    assert_equal %w[a b c], stored
  end

  def test_call_many_waits_for_every_child_before_raising_the_first_failure
    finished = Queue.new
    child = Tamoz.graph(name: 'fanout-failing-child', version: '1') do
      state :label, default: ''
      node(:work, implementation_name: 'fanout.failing.child', version: '1') do |state, _context|
        raise "child #{state[:label]} failed" if state[:label] == 'a'

        sleep 0.05
        finished << state[:label]
        {}
      end
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end.compile
    parent = Tamoz.graph(name: 'fanout-failing-parent', version: '1') do
      state :done, default: false
      node(:fan, implementation_name: 'fanout.failing.parent', version: '1') do |_state, context|
        child.call_many(%w[a b c].map { |label| { label: } }, context)
        { done: true }
      end
      edge Tamoz::START, :fan
      edge :fan, Tamoz::END
    end.compile(checkpointer: Tamoz::Graph::MemoryCheckpointer.new)

    result = parent.invoke({}, thread: 'thread:fail', request_id: 'r1', execution_id: 'e1', concurrency: :inline)

    assert_predicate result, :failed?
    assert_equal %w[b c], Array.new(finished.length) { finished.pop }.sort
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
