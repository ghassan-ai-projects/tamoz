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
end
