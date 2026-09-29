# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/subagent_fixtures'

class SubagentShowTest < Minitest::Test
  include SubagentFixtures

  def test_show_json_reports_child_events_and_separate_model_usage
    with_show_view do |view, cli|
      document = cli.send(:build_show_document, view, thread_id: 'work', transcript: 5)

      assert_equal(%w[subagent_started subagent_finished],
                   document.fetch('subagent_events').map { |event| event['event'] })
      assert_equal 2, document.dig('turn_usage', 'children', 'model_calls')
    end
  end

  def test_show_human_reports_child_events_and_separate_model_usage
    with_show_view do |view, cli, out|
      cli.send(:render_show_human, view, thread_id: 'work', transcript: 5)

      assert_includes out.string, 'explore: done (2 model calls, 2 tool calls)'
      assert_includes out.string, 'Model calls: 2 parent, 2 children'
    end
  end

  private

  def with_show_view
    with_work_workspace(files: EXPLORE_FILES) do |root, adapter|
      model = ScriptedTeam.new(parent: delegate_once, child: HAPPY_CHILD)
      session = subagent_session(model:, root:, adapter:)
      session.start(TASK, thread: 'work', request_id: 'work-1')
      out = StringIO.new
      cli = Tamoz::Agent::CLI.new(out:, err: StringIO.new, input: StringIO.new, env: {})
      yield session.view(thread: 'work'), cli, out
    end
  end
end
