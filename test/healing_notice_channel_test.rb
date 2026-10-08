# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'
require_relative 'support/experience_harness'

# A failed chat turn reaches the person on the channel twice: the turn's own failure reply, then the healing
# notice that it needs them. Driven through the gateway, worker and outbox with a scripted provider (plumbing).
class HealingNoticeChannelTest < Minitest::Test
  class ProviderDown < WorkLoopFixtures::ScriptedConversationModel
    def converse(**)
      raise Tamoz::Agent::ModelCallError.new(code: 'http_error', status: 503)
    end
  end

  def test_a_failed_turn_tells_the_channel_it_needs_a_person
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: ->(**) { ProviderDown.new(turns: []) }, routing: :work)
    texts = harness.say('Hello').map { |card| card[:text].to_s }

    assert_equal 2, texts.length, texts.inspect
    assert_includes texts.first, 'model provider is having trouble'
    assert_match(/dependency unavailable.*escalated to you/, texts.last)
  ensure
    harness&.close
  end
end
