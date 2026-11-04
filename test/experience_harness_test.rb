# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/experience_harness'

module ExperienceHarnessScenarios
  Fixture = Tamoz::Evals::Benchmark::OpenclawCommsFixture
  TERMINAL_KINDS = %w[answer completed failed blocked stopped].freeze

  NEEDS_INPUT_REVIEW = { 'decision' => 'needs_input', 'layer' => 'semantic', 'review_id' => 'rv1',
                         'issues' => ['Which file did you mean — note.txt or other.txt?'],
                         'rationale' => 'ambiguous request' }.freeze

  def open_harness(**)
    harness = Tamoz::ExperienceSim::Harness.new(**)
    @opened << harness
    harness
  end

  def clarifying_harness(*later_reviews)
    review = [NEEDS_INPUT_REVIEW, *later_reviews]
    open_harness(model_factory: Fixture.model_factory(plan: Fixture::DEFAULT_PLAN, review:, verify: Fixture::VERIFY_OK))
  end

  def routed_harness(*routes)
    open_harness(model_factory: Fixture.model_factory(route: routes), routing: :experimental)
  end

  def direct_route(answer, reason_class)
    { 'route' => 'direct_response', 'answer' => answer, 'reason_class' => reason_class }
  end

  def refused_provider_harness
    provider = Object.new
    def provider.generate(**) = raise(Tamoz::Agent::ModelCallError.new(code: 'http_failure', status: 402))
    open_harness(model_factory: ->(**) { provider }, routing: :experimental)
  end

  def terminal_card(cards)
    cards.reverse.find { |card| TERMINAL_KINDS.include?(card[:kind]) }
  end

  def failed_events(harness)
    harness.events.select { |event| event['event'] == 'request.failed' }
  end

  def request_history(harness)
    harness.instance_variable_get(:@runtime).checkpoints.request_history(
      thread_id: harness.conversation_status.fetch('thread_id')
    )
  end

  def planning_operations(harness)
    harness.effect_census.map { |row| row[:operation] }
                         .select { |operation| operation.to_s.include?('plan') || operation.to_s.include?('review') }
  end

  def status_lease
    Tamoz::Comms::Lease.new(owner: 'status-test', fence: 1).wire
  end

  def build_delivery(request_id, content_digest)
    Tamoz::Comms::Delivery.build(
      conversation_id: Fixture::CONVERSATION_A, kind: 'answer', text: "delivery for #{request_id}",
      journaled: true, render_version: 1, content_digest:, identity_key: request_id
    ).wire
  end
end

# Plumbing guard for Harness A (the mock-Telegram experience harness). Uses the
# fixture's DETERMINISTIC scripted provider — this proves the harness drives the
# real gateway/worker/outbox/drainer and captures outbound cards. It is NOT
# intelligence or real-experience evidence; that requires a real provider run
# via bin/tamoz-chat-sim.
class ExperienceHarnessTest < Minitest::Test
  include ExperienceHarnessScenarios

  def setup
    @opened = []
    @harness = open_harness(model_factory: Fixture.model_factory(**Fixture::DEFAULT_MODEL_RESPONSES))
  end

  def teardown
    @opened&.each(&:close)
  end

  def test_a_user_message_is_admitted_and_answered_through_the_real_chain
    cards = @harness.say('answer the task')

    kinds = cards.map { |card| card[:kind] }

    assert_equal 1, cards.length, "one reply per message, got: #{kinds.inspect}"
    terminal = cards.reverse.find { |card| TERMINAL_KINDS.include?(card[:kind]) }

    refute_nil terminal, "expected a terminal card, got kinds: #{kinds.inspect}"
  end

  def test_outbound_is_captured_per_turn
    first = @harness.say('answer the task')

    refute_empty first, 'first turn should produce its answer'
  end

  def test_clarification_pause_projects_a_bounded_question_without_approval_evidence
    cards = clarifying_harness.say('read the file and summarize it')
    question_cards = cards.select { |card| card[:kind] == 'control' }

    assert_equal([%w[answer]], question_cards.map { |card| JSON.parse(card.fetch(:markup)).fetch('actions') })
    assert_match(/Which file did you mean/, question_cards.first.fetch(:text))
    refute_includes cards.map { |card| card[:kind] }, 'approval_request'
  end

  def test_clarification_pause_records_a_paused_request_that_has_not_failed
    harness = clarifying_harness
    harness.say('read the file and summarize it')
    paused = harness.events.find { |event| event['event'] == 'request.paused' }

    assert_empty failed_events(harness)
    assert_equal 'clarification_required', paused&.fetch('reason')
    assert_equal 1, harness.conversation_status.fetch('open_requests')
  end

  def test_clarification_pause_gives_the_open_request_a_short_reference
    harness = clarifying_harness
    harness.say('read the file and summarize it')

    assert_match(/\Ar[0-9a-f]{10}\z/, harness.reference)
  end

  def test_clarification_answer_resumes_the_same_occurrence
    harness = clarifying_harness(Fixture::ACCEPTED_REVIEW)
    question = harness.say('read the file and summarize it').find { |card| card[:kind] == 'control' }
    expected_ref = harness.reference

    resumed = harness.reply('note.txt')
    references = harness.request_ids_for(Fixture::CONVERSATION_A).map { |id| Tamoz::Comms::Lifecycle::RequestRef.for(id) }

    assert_equal [expected_ref], references
    assert resumed.any? { |card| TERMINAL_KINDS.include?(card[:kind]) },
           "expected the clarification answer to finish the original occurrence; got: #{resumed.inspect}"
    assert_match(/Which file did you mean/, question.fetch(:text))
  end

  def test_clarification_answer_command_skips_an_earlier_fresh_turn
    harness = clarifying_harness(Fixture::ACCEPTED_REVIEW)
    harness.say('read the file and summarize it')
    reference = harness.reference
    harness.admit('also inspect other.txt')

    resumed = harness.say("/answer #{reference} note.txt")

    assert_equal([%i[turn completed], %i[turn queued], %i[resume completed]],
                 request_history(harness).map { |request| [request.operation, request.status] })
    assert_includes resumed.map { |card| card[:kind] }, 'answer'
    assert_empty failed_events(harness)
  end

  def test_reply_without_a_pending_question_remains_a_new_request
    first = @harness.say('answer the task')

    refute_empty first

    second = @harness.reply('thanks, also what about other.txt?')

    assert(second.any? { |card| TERMINAL_KINDS.include?(card[:kind]) })
    assert_equal 2, @harness.request_ids_for(Fixture::CONVERSATION_A).length
  end

  # OF-4 / I4 (finished worker migration): a conversational turn is routed to a
  # direct answer in the worker — no plan, no review, no PlanRejectedError — and
  # its terminal card is the answer alone. The turn is still a durable request.
  def test_a_provider_that_refuses_the_call_is_named_in_a_plain_reply_then_escalated
    cards = refused_provider_harness.say('hi')

    assert_equal([['failed', Tamoz::Agent::ChatReply::REASONS.fetch('model_out_of_credit')]],
                 cards.first(1).map { |card| [card[:kind], card[:text]] })
    assert_equal 2, cards.length
    assert_match(/resource exhausted.*escalated to you/, cards.fetch(1)[:text])
  end

  def test_a_provider_that_refuses_the_call_fails_the_request_as_out_of_credit
    harness = refused_provider_harness
    harness.say('hi')

    assert(harness.events.any? do |event|
      event['event'] == 'request.failed' && event['reason'] == 'model_out_of_credit'
    end)
  end

  def test_a_sticker_from_the_correspondent_says_what_the_bot_reads
    @harness.transport.enqueue('update_id' => 9_001, 'message' => {
                                 'message_id' => 9_001, 'date' => Time.now.to_i,
                                 'from' => { 'id' => Fixture::USER_BOUND },
                                 'chat' => { 'id' => 22_222_222, 'type' => 'private' },
                                 'sticker' => { 'file_id' => 's', 'file_unique_id' => 'u-s' }
                               })

    @harness.send(:serve)
    cards = @harness.work_off

    assert_equal([Tamoz::Comms::Admission::UNSUPPORTED_REPLY], cards.map { |card| card[:text] })
    assert_empty @harness.request_ids_for(Fixture::CONVERSATION_A), 'a sticker is not a task'
  end

  def test_conversational_turn_is_routed_to_a_direct_answer_without_planning
    harness = routed_harness(direct_route('Hello there.', 'greeting'))

    cards = harness.say('hi')

    assert_equal 'Hello there.', terminal_card(cards)&.fetch(:text),
                 "expected a terminal answer, got: #{cards.map { |card| card[:kind] }.inspect}"
    assert_empty failed_events(harness), 'a routed chat turn must not reach a plan/review failure'
    assert_empty planning_operations(harness), 'a direct chat turn must not run plan/review'
  end

  # A chat answer can be multi-line, and the
  # confirmed transcript feeds the NEXT turn's context. TurnContext forbids
  # control characters, so a second chat turn must not crash on the stored
  # newline — the store flattens transcript fragments before they become context.
  def test_second_chat_turn_does_not_crash_on_a_multiline_answer_in_history
    harness = routed_harness(direct_route('Hello there.', 'greeting'),
                             direct_route('Two plus two is four.', 'general_knowledge'))

    harness.say('hi')
    second = harness.say('what is 2 + 2?')

    assert_empty failed_events(harness), 'the second chat turn must not fail on a control character in history'
    assert_equal 'Two plus two is four.', terminal_card(second).fetch(:text)
  end

  def test_bare_cancel_stops_every_open_request
    @harness.admit('prepare the report')
    @harness.admit('draft the email')

    cards = @harness.say('/cancel')

    assert_includes cards.map { |card| [card[:kind], card[:text]] }, %w[control Stopping…]
    assert_every_request_is_stamped
  end

  def test_a_second_cancel_stops_the_newer_message_too
    @harness.admit('prepare the report')
    @harness.say('/cancel')
    @harness.admit('draft the email')
    cards = @harness.say('/cancel')

    assert_includes cards.map { |card| card[:text] }, 'Stopping…'
    assert_every_request_is_stamped
  end

  def test_cancel_reference_targets_one_open_request
    @harness.admit('prepare the report')
    @harness.admit('draft the email')
    second_reference = @harness.reference(1)

    cards = @harness.say("/cancel #{@harness.reference(0)}")
    stamps = stamps_by_request
    first_id, second_id = @harness.request_ids_for(Fixture::CONVERSATION_A)

    refute_nil stopping_reply(cards), "expected a reference-addressed cancellation, got: #{cards.inspect}"
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
    @harness.admit('prepare the report')
    reference = @harness.reference
    request_id = @harness.request_ids_for(Fixture::CONVERSATION_A).first

    assert_equal "Your message is queued; I'll start on it shortly.", queued_status_text(reference)

    @harness.work_off

    assert_equal 'completed', @harness.ref_status(reference).fetch('task_state')
    effect_keys = effect_keys_for(request_id)

    assert_equal effect_keys.length, effect_keys.uniq.length
  end

  def test_conversational_turn_is_answered_directly_without_plan_lifecycle
    harness = routed_harness(direct_route('Hello there.', 'greeting'))

    kinds = harness.say('hi').map { |card| card[:kind] }

    assert_equal %w[answer], kinds
    assert_equal 'direct_response', harness.snapshot.fetch('session')
                                           .fetch(Fixture::CONVERSATION_A).fetch('terminal_reason')
    assert_equal(['model.generate.route'], harness.effect_census.map { |row| row.fetch(:operation) })
  end

  def test_clarification_resume_request_is_bound_to_the_answered_occurrence
    harness = clarifying_harness
    harness.say('read the file and summarize it')
    target_id = harness.request_ids_for(Fixture::CONVERSATION_A).fetch(0)
    reference = harness.reference

    harness.say("/answer #{reference} note.txt")
    resume = request_history(harness).find { |request| request.operation == :resume }

    assert_equal target_id, Tamoz::Comms::ClarificationAnswerRequest.target_id(resume.request_id)
  end

  private

  def assert_every_request_is_stamped
    requests = @harness.request_ids_for(Fixture::CONVERSATION_A)
    stamps = @harness.cancellation_stamp_rows

    assert_equal 2, requests.length
    assert_equal requests.sort, stamps.map { |row| row.fetch('request_id') }.sort
    stamps.each { |row| refute_nil row.fetch('requested_at_ms') }
  end

  def request_status_text(reference)
    cards = @harness.say("/status #{reference} --diagnostic")
    cards.find { |card| card[:kind] == 'control' && card[:text].start_with?("Request #{reference}:") }.fetch(:text)
  end

  def stopping_reply(cards)
    cards.find { |card| card[:kind] == 'control' && card[:text] == 'Stopping…' }
  end

  def stamps_by_request
    @harness.cancellation_stamp_rows.to_h { |row| [row.fetch('request_id'), row] }
  end

  def queued_status_text(reference)
    @harness.status_only(reference).find { |card| card[:kind] == 'control' }.fetch(:text)
  end

  def effect_keys_for(request_id)
    @harness.effect_census.select { |row| row[:request_id] == request_id }.map { |row| row.fetch(:effect_key) }
  end

  def record_delivery(request_id, status:, content_digest:)
    store = @harness.store
    now = @harness.now
    delivery = build_delivery(request_id, content_digest)
    delivery_id = delivery.fetch('delivery_id')

    assert_equal :appended, store.append_delivery(
      delivery, surface_id: Fixture::SURFACE_ID, capacity: 500, reserved_request_id: request_id, now:
    )
    assert_equal :claimed, store.claim_delivery(
      delivery_id:, lease: status_lease, claim_expires_at: now + 30, now:
    )
    if status == 'unknown'
      assert_equal :marked, store.mark_delivery_send_started(delivery_id:, lease: status_lease, now: now + 1)
    end

    assert_equal :marked, store.mark_delivery(
      delivery_id:, lease: status_lease, status:, receipt: status == 'succeeded' ? { 'message_id' => 1 } : nil,
      now: now + 2
    )
  end
end
