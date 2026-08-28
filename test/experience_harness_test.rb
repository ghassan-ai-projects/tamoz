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

  def test_bare_cancel_disambiguates_multiple_open_requests_without_mutating_them
    first = @harness.admit('prepare the report')
    second = @harness.admit('draft the email')
    references = [first, second].map { |cards| cards.fetch(0).fetch(:text)[/\br[0-9a-f]{10}\b/] }

    cards = @harness.say('/cancel')
    reply = cards.find { |card| card[:kind] == 'control' && card[:text].include?('Choose one') }

    refute_nil reply, "expected a cancellation choice, got: #{cards.inspect}"
    references.each { |reference| assert_includes reply.fetch(:text), reference }
    assert @harness.cancellation_stamp_rows.all? { |row| row.fetch('requested_at_ms').nil? },
           'ambiguous cancellation must not stamp any request'
  end

  def test_cancel_reference_targets_one_open_request
    first = @harness.admit('prepare the report')
    second = @harness.admit('draft the email')
    first_reference = first.fetch(0).fetch(:text)[/\br[0-9a-f]{10}\b/]
    second_reference = second.fetch(0).fetch(:text)[/\br[0-9a-f]{10}\b/]

    cards = @harness.say("/cancel #{first_reference}")
    reply = cards.find { |card| card[:kind] == 'control' && card[:text].include?(first_reference) }

    refute_nil reply, "expected a reference-addressed cancellation, got: #{cards.inspect}"
    stamps = @harness.cancellation_stamp_rows.to_h { |row| [row.fetch('request_id'), row] }
    requests = @harness.request_ids_for(Fixture::CONVERSATION_A)
    first_id, second_id = requests

    refute_nil stamps.fetch(first_id).fetch('requested_at_ms')
    assert_nil stamps.fetch(second_id).fetch('requested_at_ms'),
               "#{second_reference} must remain unstamped"
  end

  def test_request_status_is_request_local_for_two_delivery_outcomes
    @harness.admit('prepare the report')
    @harness.admit('draft the email')
    first_id, second_id = @harness.request_ids_for(Fixture::CONVERSATION_A)
    first_reference = Tamoz::Comms::Lifecycle::RequestRef.for(first_id)
    second_reference = Tamoz::Comms::Lifecycle::RequestRef.for(second_id)

    record_delivery(first_id, status: 'unknown', content_digest: 'a' * 64)
    record_delivery(second_id, status: 'succeeded', content_digest: 'b' * 64)

    first_status = request_status_text(first_reference)
    second_status = request_status_text(second_reference)

    assert_match(/Request #{first_reference}:.*delivery=unknown/, first_status)
    assert_match(/Request #{second_reference}:.*delivery=delivered/, second_status)
  end

  def test_worker_unavailable_state_is_distinct_from_working
    accepted = @harness.admit('prepare the report')
    reference = accepted.first.fetch(:text)[/\br[0-9a-f]{10}\b/]
    request_id = @harness.request_ids_for(Fixture::CONVERSATION_A).first

    queued = @harness.status_only(reference)
    queued_text = queued.find { |card| card[:kind] == 'control' }.fetch(:text)

    assert_match(/worker=queued-unclaimed/, queued_text)

    @harness.work_off

    completed = @harness.ref_status(reference)
    assert_equal 'completed', completed.fetch('task_state')
    effects = @harness.effect_census.select { |row| row[:request_id] == request_id }
    assert_equal effects.length, effects.map { |row| row.fetch(:effect_key) }.uniq.length
  end

  private

  def request_status_text(reference)
    cards = @harness.say("/status #{reference}")
    cards.find { |card| card[:kind] == 'control' && card[:text].start_with?("Request #{reference}:") }.fetch(:text)
  end

  def record_delivery(request_id, status:, content_digest:)
    store = @harness.store
    now = @harness.now
    delivery = Tamoz::Comms::Delivery.build(
      conversation_id: Fixture::CONVERSATION_A, kind: 'answer', text: "delivery for #{request_id}",
      journaled: true, render_version: 1, content_digest:, identity_key: request_id
    ).wire

    assert_equal :appended, store.append_delivery(
      delivery, surface_id: Fixture::SURFACE_ID, capacity: 500,
      reserved_request_id: request_id, now:
    )
    assert_equal :claimed, store.claim_delivery(
      delivery_id: delivery.fetch('delivery_id'), owner: 'status-test', fence: 1,
      claim_expires_at: now + 30, now:
    )
    if status == 'unknown'
      assert_equal :marked, store.mark_delivery_send_started(
        delivery_id: delivery.fetch('delivery_id'), owner: 'status-test', fence: 1, now: now + 1
      )
    end
    assert_equal :marked, store.mark_delivery(
      delivery_id: delivery.fetch('delivery_id'), owner: 'status-test', fence: 1,
      status:, receipt: status == 'succeeded' ? { 'message_id' => 1 } : nil, now: now + 2
    )
  end
end
