# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/subagent_spec'

# Quality-bar rows C2 and C3: a re-run of the parent's gate node and the user's stop, with a subagent run inside the
# parent's turn. C1, the real process kill, is test/subagent_kill_test.rb.
class SubagentDurabilityTest < Minitest::Test
  include SubagentSpec

  Crash = WorkLoopFixtures::ScriptedConversationModel::Crash

  # Dies once the child has finished but before the parent's gate node has checkpointed its own result.
  class CrashInParentGateAfterChild
    def initialize = @child_finished = false

    def emit(type, _namespace, data = {}, **) # rubocop:disable Naming/PredicateMethod -- the emitter interface
      return false unless type == :task_end

      @child_finished ||= data['graph'] == 'tamoz.agent.subagent' && data['node'] == 'terminal'
      raise Crash, 'simulated worker loss after the child finished' if
        @child_finished && data['graph'] == 'tamoz.agent.session' && data['node'] == 'work_gate'

      false
    end
  end

  def test_a_rerun_gate_node_returns_the_stored_child_result_without_calling_the_child_model
    spec_row('C2') do
      with_work_workspace(files: EXPLORE_FILES) do |root, adapter|
        first = SubagentFixtures::ScriptedTeam.new(parent: delegate_once, child: HAPPY_CHILD)
        assert_raises(Crash) do
          subagent_session(model: first, root:, adapter:)
            .start(TASK, thread: 'work', request_id: 'work-1', emitter: CrashInParentGateAfterChild.new)
        end
        assert_child_ran(first)
        second = SubagentFixtures::ScriptedTeam.new(parent: [{ content: 'Totals round in two places.' }], child: [])
        outcome = subagent_session(model: second, root:, adapter:).recover(thread: 'work', request_id: 'work-1')

        assert_equal HAPPY_CHILD.length, first.child_requests.length
        assert_empty second.child_requests
        assert_equal 1, second.parent_requests.length
        assert_equal 'answered', outcome.state.fetch(:terminal_reason)
        assert_equal uncrashed_result(root, HAPPY_CHILD), delegation_results(second).first
      end
    end
  end

  def test_a_stop_during_the_child_ends_the_child_and_then_the_parent_with_no_further_model_call
    spec_row('C3') do
      token = Tamoz::CancellationToken.new
      child = [{ calls: [read_call('lib/a.rb')] }, lambda { |_|
        token.cancel!('user stop')
        { calls: [read_call('lib/b.rb')] }
      }]
      with_work_workspace(files: EXPLORE_FILES) do |root, adapter|
        model = SubagentFixtures::ScriptedTeam.new(parent: [{ calls: [delegate_call] }], child:)
        session = subagent_session(model:, root:, adapter:)
        outcome = Tamoz::Cancellation::Stops.during('work', token) do
          session.start(TASK, thread: 'work', request_id: 'work-1')
        end

        assert_child_ran(model)
        results = entry_texts(adapter, outcome.state.fetch(:work_entries)).map(&:last).grep(/\ASubagent explore:/)

        assert_equal 'cancelled_by_user', outcome.state.fetch(:terminal_reason)
        assert_match(/\ASubagent explore: cancelled/, results.first)
        assert_equal [1, 2], [model.parent_requests.length, model.child_requests.length]
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
