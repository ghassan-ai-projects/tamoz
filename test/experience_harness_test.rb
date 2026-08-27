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

  def test_clarification_pause_projects_a_bounded_question_without_approval_evidence
    review = [{ 'decision' => 'needs_input', 'layer' => 'semantic', 'review_id' => 'rv1',
                'issues' => ['Which file did you mean — note.txt or other.txt?'],
                'rationale' => 'ambiguous request' }]
    scripted = Fixture.model_factory(plan: Fixture::DEFAULT_PLAN, review:, verify: Fixture::VERIFY_OK)
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: scripted)

    cards = harness.say('read the file and summarize it')
    question_cards = cards.select { |card| card[:kind] == 'control' }
    accepted = cards.find { |card| card[:kind] == 'accepted' }
    paused = harness.events.find { |event| event['event'] == 'request.paused' }

    assert_equal 1, question_cards.length
    assert_match(/Which file did you mean/, question_cards.first.fetch(:text))
    assert_equal %w[answer], JSON.parse(question_cards.first.fetch(:markup)).fetch('actions')
    refute_includes cards.map { |card| card[:kind] }, 'approval_request'
    refute harness.events.any? { |event| event['event'] == 'request.failed' }
    refute_nil paused
    assert_equal 'clarification_required', paused.fetch('reason')
    assert_equal 1, harness.conversation_status.fetch('open_requests')
    assert_match(/\br[0-9a-f]{10}\b/, accepted.fetch(:text))
  ensure
    harness&.close
  end

  def test_clarification_answer_resumes_the_same_occurrence
    review = [
      { 'decision' => 'needs_input', 'layer' => 'semantic', 'review_id' => 'rv1',
        'issues' => ['Which file did you mean — note.txt or other.txt?'],
        'rationale' => 'ambiguous request' },
      Fixture::ACCEPTED_REVIEW
    ]
    scripted = Fixture.model_factory(plan: Fixture::DEFAULT_PLAN, review:, verify: Fixture::VERIFY_OK)
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: scripted)

    initial = harness.say('read the file and summarize it')
    accepted = initial.find { |card| card[:kind] == 'accepted' }
    question = initial.find { |card| card[:kind] == 'control' }

    resumed = harness.reply('note.txt')
    request_ids = harness.request_ids_for(Fixture::CONVERSATION_A)

    assert_equal 1, request_ids.length
    expected_ref = accepted.fetch(:text)[/\br[0-9a-f]{10}\b/]
    actual_ref = Tamoz::Comms::Lifecycle::RequestRef.for(request_ids.first)
    assert_equal expected_ref, actual_ref
    refute_includes resumed.map { |card| card[:kind] }, 'accepted'
    assert resumed.any? { |card| TERMINAL_KINDS.include?(card[:kind]) },
           "expected the clarification answer to finish the original occurrence; got: #{resumed.inspect}"
    assert_match(/Which file did you mean/, question.fetch(:text))
  ensure
    harness&.close
  end

  def test_clarification_answer_command_skips_an_earlier_fresh_turn
    review = [
      { 'decision' => 'needs_input', 'layer' => 'semantic', 'review_id' => 'rv1',
        'issues' => ['Which file did you mean — note.txt or other.txt?'],
        'rationale' => 'ambiguous request' },
      Fixture::ACCEPTED_REVIEW
    ]
    scripted = Fixture.model_factory(plan: Fixture::DEFAULT_PLAN, review:, verify: Fixture::VERIFY_OK)
    harness = Tamoz::ExperienceSim::Harness.new(model_factory: scripted)

    initial = harness.say('read the file and summarize it')
    accepted = initial.find { |card| card[:kind] == 'accepted' }
    reference = accepted.fetch(:text)[/\br[0-9a-f]{10}\b/]
    harness.admit('also inspect other.txt')

    resumed = harness.say("/answer #{reference} note.txt")
    thread = harness.conversation_status.fetch('thread_id')
    history = harness.instance_variable_get(:@runtime).checkpoints.request_history(thread_id: thread)

    assert_equal %i[turn turn resume], history.map(&:operation)
    assert_equal %i[completed queued completed], history.map(&:status)
    refute_includes resumed.map { |card| card[:kind] }, 'accepted'
    assert_includes resumed.map { |card| card[:kind] }, 'answer'
    refute harness.events.any? { |event| event['event'] == 'request.failed' }
  ensure
    harness&.close
  end

  def test_reply_without_a_pending_question_remains_a_new_request
    first = @harness.say('answer the task')
    refute_empty first

    second = @harness.reply('thanks, also what about other.txt?')

    assert_includes second.map { |card| card[:kind] }, 'accepted'
    assert_equal 2, @harness.request_ids_for(Fixture::CONVERSATION_A).length
  end
end
