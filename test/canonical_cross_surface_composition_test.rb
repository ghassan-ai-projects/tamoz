# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/evals/benchmark/openclaw_comms_oracles'
require_relative 'support/canonical_composition_steps'

class CanonicalCrossSurfaceCompositionTest < Minitest::Test
  include CanonicalCompositionSteps

  def test_canonical_cross_surface_composition_story
    fixture = Fixture.new(model_factory: ->(_options) { build_routes },
                          admission_mode: :pairing,
                          approval_ask: { timeout_s: 86_400, on_timeout: :park })
    drive_story(fixture)
  ensure
    fixture&.close
  end

  private

  def drive_story(fixture)
    @clock = fixture.now
    telegram_legs, cli_legs = pair_both_conversations(fixture)
    slow_turn_cancel_timeline(fixture)
    crash_recovery_and_delivery_faults(fixture)
    cross_cutting_oracle_score(fixture, telegram_legs:, cli_legs:)
  end

  def pair_both_conversations(fixture)
    code_a = pairing_code(fixture, 101, USER_A, CONVERSATION_A)
    approve_pairing(fixture, code_a, USER_A, CONVERSATION_A)

    assert_pairing_binds_only_conversation_a(fixture)

    code_b = pairing_code(fixture, 102, USER_B, CONVERSATION_B)

    assert_code_a_cannot_pair_conversation_b(fixture, code_a)
    approve_pairing(fixture, code_b, USER_B, CONVERSATION_B)
    admit_all_legs(fixture)
  end

  def assert_pairing_binds_only_conversation_a(fixture)
    paired_a = fixture.store.bindings(surface_id: SURFACE_ID).select do |row|
      row['status'] == 'active' && row['correspondent_id'] == "telegram:user:#{USER_A}"
    end

    assert_equal [CONVERSATION_A], paired_a.map { |row| row['conversation_id'] },
                 'approving one code must bind exactly its own conversation'
  end

  def assert_code_a_cannot_pair_conversation_b(fixture, code_a)
    pending_b = fixture.store.pairing_challenges(status: 'pending', now: fixture.now)
                       .find { |row| row.fetch('conversation_id') == CONVERSATION_B }

    assert pending_b, 'conversation B challenge missing'
    refute PairingChallenge.verify?(
      challenge: code_a, digest: pending_b.fetch('challenge_digest'),
      surface_id: SURFACE_ID, correspondent_id: pending_b.fetch('correspondent_id'),
      conversation_id: CONVERSATION_B
    ), 'conversation A code must not pair conversation B'
  end

  def admit_all_legs(fixture)
    telegram_leg_a = admitted_telegram_turn(fixture, CONVERSATION_A, USER_A, 110,
                                            "Please read the workspace note. #{MARKER_ONE_A}")
    cli_leg_a = admitted_cli_turn(fixture, CONVERSATION_A, 'parity_leg_a',
                                  "Report operator state. #{MARKER_OPS_A}")
    telegram_leg_b = admitted_telegram_turn(fixture, CONVERSATION_B, USER_B, 120,
                                            "Please read the workspace note. #{MARKER_ONE_B}")
    cli_leg_b = admitted_cli_turn(fixture, CONVERSATION_B, 'parity_leg_b',
                                  "Report operator state. #{MARKER_OPS_B}")
    [[telegram_leg_a, telegram_leg_b], [cli_leg_a, cli_leg_b]]
  end

  def slow_turn_cancel_timeline(fixture)
    thread = fixture.thread_for(CONVERSATION_A)
    park_slow_turn(fixture, thread)
    request_id = fixture.request_ids_for(CONVERSATION_A).last
    reference = Lifecycle::RequestRef.for(request_id)
    cancel_parked_turn(fixture, thread, request_id)

    assert_diagnostic_status_reports_the_stop(fixture, reference)
    drain_all(fixture)
  end

  def park_slow_turn(fixture, thread)
    submit_update(fixture, raw_update(130, "Fix note.txt to say fixed. #{MARKER_SLOW}",
                                      user_id: USER_A, conversation_id: CONVERSATION_A))
    fixture.work

    assert_equal :paused, fixture.view(thread)&.status, 'slow turn never parked on the approval ask'
    prompt = fixture.outbox.any? do |row|
      row['conversation_id'] == CONVERSATION_A && row['kind'] == 'approval_request'
    end

    assert prompt, 'the parked turn never asked for approval'
  end

  def cancel_parked_turn(fixture, thread, request_id)
    cancel_reply = control_reply(fixture, raw_update(131, '/cancel', user_id: USER_A,
                                                                     conversation_id: CONVERSATION_A))

    assert_equal 'Stopping…', cancel_reply&.fetch('text')

    observed = fixture.store.mark_cancellation_observed(thread_id: thread, now: @clock)

    assert_equal :observed, observed

    timeline = cancellation_timeline(fixture, CONVERSATION_A, request_id)

    assert timeline[:requested_present], 'requested stamp missing'
    assert timeline[:observed_present], 'observed stamp missing'
    assert timeline[:requested_le_observed], 'observation precedes the request'
    assert_equal 'terminal', timeline[:state]
    assert_equal 'stopped', timeline[:terminal_word]
  end

  def assert_diagnostic_status_reports_the_stop(fixture, reference)
    status_reply = control_reply(fixture, raw_update(132, "/status #{reference} --diagnostic",
                                                     user_id: USER_A, conversation_id: CONVERSATION_A))
    text = status_reply&.fetch('text').to_s

    assert_includes text, reference, text
    assert_includes text, 'Terminal: stopped at the cancellation boundary.', text
    refute_includes text, 'completed before the cancellation took effect', text
  end

  def crash_recovery_and_delivery_faults(fixture)
    conversation = CONVERSATION_B
    crash_update = raw_update(140, "Summarize both notes. #{MARKER_CRASH}",
                              user_id: USER_B, conversation_id: conversation)
    submit_update(fixture, crash_update)
    killed =
      begin
        fixture.work
        false
      rescue Fixture::Killed
        true
      end

    assert killed, 'the scripted model never fired the kill-style crash'
    refute terminal_view?(fixture, conversation), 'crashed turn settled anyway'

    work_until_terminal(fixture, conversation, worker: fixture.fresh_worker)
    drain_all(fixture)

    duplicate_replays_harmlessly(fixture, crash_update)
    oversized_then_admitted(fixture)
    ambiguous_send_never_resent(fixture)
  end

  def duplicate_replays_harmlessly(fixture, crash_update)
    conversation = CONVERSATION_B
    sends_before = fixture.transport.sends.length
    requests_before = fixture.request_ids_for(conversation).length
    submit_update(fixture, crash_update)
    drain_all(fixture)

    assert_equal sends_before, fixture.transport.sends.length, 'duplicate replay sent again'
    assert_equal requests_before, fixture.request_ids_for(conversation).length,
                 'duplicate replay enqueued a second request'
  end

  def oversized_then_admitted(fixture)
    # The envelope bound and the default intake limit coincide at 8192, so a
    # revision bump tightening the DEPLOYED limit is what makes admission's
    # typed oversize refusal reachable through the real Normalizer seam.
    tighten_surface_limit(fixture, max_inbound_bytes: 4096)
    requests_before = fixture.request_ids_for(CONVERSATION_B).length

    assert_oversized_update_refused(fixture, requests_before)
    admit_final_question(fixture, requests_before)
    drain_all(fixture)
    work_until_terminal(fixture, CONVERSATION_B, worker: fixture.fresh_worker)
  end

  def assert_oversized_update_refused(fixture, requests_before)
    refusal = control_reply(fixture, raw_update(150, 'x' * 6000, user_id: USER_B,
                                                                 conversation_id: CONVERSATION_B))

    assert_equal "That message exceeds this channel's size limit.", refusal&.fetch('text')
    assert_equal requests_before, fixture.request_ids_for(CONVERSATION_B).length,
                 'oversized update enqueued work'
  end

  def admit_final_question(fixture, requests_before)
    submit_update(fixture, raw_update(160, "Final question for the channel. #{MARKER_FINAL}",
                                      user_id: USER_B, conversation_id: CONVERSATION_B))

    assert_equal requests_before + 1, fixture.request_ids_for(CONVERSATION_B).length,
                 'valid successor turn was not admitted'
  end

  def ambiguous_send_never_resent(fixture)
    fault_the_pending_answer_send(fixture)

    assert_one_unknown_answer_without_receipt(fixture)
    assert_unknown_delivery_is_not_resent(fixture)

    view = fixture.view(fixture.thread_for(CONVERSATION_B))

    assert_equal :completed, view&.status, 'task truth must survive the delivery ambiguity'
  end

  def fault_the_pending_answer_send(fixture)
    pending = fixture.outbox(statuses: %w[pending])
    answer_index = pending.index { |row| row['kind'] == 'answer' }

    assert answer_index, 'no pending terminal answer to fault'
    fixture.transport.send_script = Array.new(answer_index) +
                                    [AmbiguousDeliveryError.new('timeout after send')]
    fixture.drain
  end

  def assert_one_unknown_answer_without_receipt(fixture)
    unknown = fixture.outbox(statuses: %w[unknown])

    assert_equal 1, unknown.length, 'exactly one send must land unknown'
    assert_equal 'answer', unknown.first.fetch('kind')
    assert_nil unknown.first['receipt'], 'an ambiguous send must carry no receipt'
  end

  def assert_unknown_delivery_is_not_resent(fixture)
    sends_before = fixture.transport.sends.length
    fixture.drain

    assert_equal sends_before, fixture.transport.sends.length, 'unknown delivery was re-sent'
    assert_equal 1, fixture.outbox(statuses: %w[unknown]).length
  end

  def cross_cutting_oracle_score(fixture, telegram_legs:, cli_legs:)
    facts = fixture.snapshot(conversations: [CONVERSATION_A, CONVERSATION_B])
                   .merge('telegram_legs' => telegram_legs, 'cli_legs' => cli_legs)

    assert_core_parity(facts)
    assert_conversation_oracles_pass(facts)
    assert_foreign_references_are_unknown(fixture)
    drain_all(fixture)

    assert_answers_reached_both_conversations(fixture, facts)
    assert_recovery_facts(fixture, facts)
  end

  def assert_core_parity(facts)
    parity = Oracles.core_parity_document(facts)

    assert_equal 1, parity.fetch('score'), parity.fetch('compared')
    Oracles::CORE_PARITY_FACTS.each do |fact|
      assert_equal 1, parity.dig('compared', fact), "#{fact} must agree across surfaces"
    end
  end

  def assert_conversation_oracles_pass(facts)
    [CONVERSATION_A, CONVERSATION_B].each do |conversation|
      assert_equal Oracles::PASS, Oracles.context_inclusion(facts, conversation),
                   "#{conversation} history must hold only its own confirmed deliveries"
      assert_equal Oracles::PASS, Oracles.first_reference_stable(facts, conversation)
    end
  end

  def assert_foreign_references_are_unknown(fixture)
    ref_a = Lifecycle::RequestRef.for(fixture.request_ids_for(CONVERSATION_A).first)
    ref_b = Lifecycle::RequestRef.for(fixture.request_ids_for(CONVERSATION_B).first)

    assert_equal :unknown_ref, fixture.request_status(CONVERSATION_A, ref_b)
    assert_equal :unknown_ref, fixture.request_status(CONVERSATION_B, ref_a)

    foreign_reply = control_reply(fixture, raw_update(170, "/status #{ref_b}", user_id: USER_A,
                                                                               conversation_id: CONVERSATION_A))

    assert_equal Gateway::UNKNOWN_REF_REPLY, foreign_reply&.fetch('text')
  end

  def assert_answers_reached_both_conversations(fixture, facts)
    assert_sends_reached_both_conversations(fixture)
    answers_b = facts['outbox'].select do |row|
      row['conversation_id'] == CONVERSATION_B && row['kind'] == 'answer'
    end

    assert_equal 4, answers_b.length
    assert_equal(1, answers_b.count { |row| row['status'] == 'unknown' })
    assert_equal 3, Oracles.confirmed_answer_texts(facts, CONVERSATION_B).length
  end

  def assert_sends_reached_both_conversations(fixture)
    sends = fixture.transport.sends.group_by { |send| send[:conversation_id] }.keys.sort

    assert_equal [CONVERSATION_A, CONVERSATION_B].sort, sends
  end

  def assert_recovery_facts(fixture, facts)
    assert_equal [%w[request accepted]], Oracles.dispositions(facts, 140)
    assert_equal [%w[rejected inbound_too_large]], Oracles.dispositions(facts, 150)

    effect_keys = fixture.effect_census.map { |row| row[:effect_key] }

    assert_equal effect_keys.uniq, effect_keys, 'recovery duplicated an effect'
    assert Oracles.c8_history_clean?(facts, CONVERSATION_A), 'a cancellation fact entered history'
  end
end
