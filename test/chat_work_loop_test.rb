# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/experience_harness'
require_relative 'support/work_loop_fixtures'

# Plumbing only: a scripted provider proves a chat turn reaches the work loop and its
# answer reaches the outbox. It is not evidence that the agent reasons.
class ChatWorkLoopTest < Minitest::Test
  include WorkLoopFixtures

  ANSWER = 'Answered from the work loop.'

  def test_a_chat_turn_runs_the_work_loop_and_its_answer_is_delivered
    model = ScriptedConversationModel.new(turns: [{ calls: [['list_directory', {}]] }, { content: ANSWER }])
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: ->(**) { model }, routing: :work)
    delivered = harness.say('what is in the workspace?').map { |card| card[:text].to_s }.join("\n")

    assert_includes delivered, ANSWER
    assert_includes JSON.parse(model.requests.first).dig('messages', 0, 'content'),
                    Tamoz::Harness::PromptPack.fetch('surface_chat')
  ensure
    harness&.close
  end

  # /cancel while the model is still answering: the call is abandoned, the answer never
  # arrives, the chat hears "Stopped." once, and the queued cancel that follows stays quiet.
  def test_cancel_stops_a_turn_whose_model_call_is_still_running
    entered = Queue.new
    release = Queue.new
    harness = story_harness(entered, release)
    harness.admit('write me a long story')
    running = Thread.new { harness.work_off }
    entered.pop

    harness.admit('/cancel')
    running.join(10)
    harness.work_off

    texts = harness.instance_variable_get(:@transport).outbound.map { |card| card[:text] }

    assert_equal ['Stopping…', 'Stopped.'], texts
  ensure
    release&.push(true)
    harness&.close
  end

  # A /cancel that lands while a tool runs: the turn must not resume and deliver its answer later.
  def test_cancel_during_a_tool_step_never_delivers_the_answer
    harness = nil
    cancel_then_call_a_tool = lambda do |_messages|
      harness.admit('/cancel')
      sleep Tamoz::Agent::Worker::STOP_POLL_SECONDS * 2
      { calls: [['list_directory', {}]] }
    end
    model = ScriptedConversationModel.new(turns: [cancel_then_call_a_tool, { content: 'the final answer' }])
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: ->(**) { model }, routing: :work)
    harness.say('look around and tell me')
    harness.work_off
    texts = harness.instance_variable_get(:@transport).outbound.map { |card| card[:text] }

    assert_equal ['Stopping…', 'Stopped.'], texts
  ensure
    harness&.close
  end

  def story_harness(entered, release)
    story = lambda do |_messages|
      entered << true
      release.pop
      { content: 'a very long story' }
    end
    model = ScriptedConversationModel.new(turns: [story])
    Tamoz::ExperienceSim::Harness.new(model_factory: ->(**) { model }, routing: :work)
  end
end
