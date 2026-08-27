# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/experience_harness'

# Plumbing guard for Harness A (the mock-Telegram experience harness). Uses the
# fixture's DETERMINISTIC scripted provider — this proves the harness drives the
# real gateway/worker/outbox/drainer and captures outbound cards. It is NOT
# intelligence or real-experience evidence; that requires a real provider run
# via bin/tamoz-chat-sim.
class ExperienceHarnessTest < Minitest::Test
  Fixture = Tamoz::Evals::Benchmark::OpenclawCommsFixture
  TERMINAL_KINDS = %w[answer completed failed blocked stopped].freeze

  def setup
    scripted = Fixture.model_factory(**Fixture::DEFAULT_MODEL_RESPONSES)
    @harness = Tamoz::ExperienceSim::Harness.new(model_factory: scripted)
  end

  def teardown
    @harness&.close
  end

  def test_a_user_message_is_admitted_and_answered_through_the_real_chain
    cards = @harness.say('answer the task')

    kinds = cards.map { |card| card[:kind] }

    assert_includes kinds, 'accepted',
                    "expected an accepted card, got: #{kinds.inspect}"

    accepted = cards.find { |card| card[:kind] == 'accepted' }

    assert_match(/\br[0-9a-f]{10}\b/, accepted[:text],
                 "accepted card should carry a caller-bound ref: #{accepted[:text].inspect}")

    terminal = cards.reverse.find { |card| TERMINAL_KINDS.include?(card[:kind]) }

    refute_nil terminal, "expected a terminal card, got kinds: #{kinds.inspect}"
  end

  def test_outbound_is_captured_per_turn
    first = @harness.say('answer the task')

    refute_empty first, 'first turn should produce at least the accepted card'
  end
end
