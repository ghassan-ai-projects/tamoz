# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/openclaw_comms_fixture'
require 'tamoz/evals/benchmark/openclaw_comms_oracles'

# Phase 3 work item 4 (docs/openclaw-chat-study/implementation-plan/
# 04-phase-3-conversation-model.md): the canonical Telegram + durable CLI
# composition as ONE continuous story over the B0 harness — real SQLite
# stores, fake scripted transport, deterministic scripted provider. Two
# isolated conversations pair, admit, cancel, crash-recover, deduplicate,
# refuse oversize, and land one ambiguous send, all scored with the
# controller-owned oracles instead of wall clocks.
class CanonicalCrossSurfaceCompositionTest < Minitest::Test
  Fixture = Tamoz::Evals::Benchmark::OpenclawCommsFixture
  Oracles = Tamoz::Evals::Benchmark::OpenclawCommsOracles
  Gateway = Tamoz::Comms::Gateway
  Lifecycle = Tamoz::Comms::Lifecycle
  PairingChallenge = Tamoz::Comms::PairingChallenge
  AmbiguousDeliveryError = Tamoz::Comms::AmbiguousDeliveryError

  CONVERSATION_A = Fixture::CONVERSATION_A
  CONVERSATION_B = Fixture::CONVERSATION_B
  # The fixture pre-binds its own USER_BOUND on conversation A even in
  # pairing mode, so the composed story pairs two correspondents of its own.
  USER_A = 31_415_926
  USER_B = 27_182_818
  SURFACE_ID = Fixture::SURFACE_ID

  MARKER_ONE_A = 'LEG-A-ONE'
  MARKER_OPS_A = 'LEG-A-OPS'
  MARKER_SLOW = 'LEG-A-SLOW'
  MARKER_ONE_B = 'LEG-B-ONE'
  MARKER_OPS_B = 'LEG-B-OPS'
  MARKER_CRASH = 'LEG-B-CRASH'
  MARKER_FINAL = 'LEG-B-FINAL'

  READ_PLAN = {
    'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
    'steps' => [{ 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                  'arguments' => { 'path' => 'note.txt' },
                  'verification' => 'the output is present' }]
  }.freeze

  # Both conversations share one profile, so the runtime memoizes ONE model
  # for every thread; prompts carry the task text, and each leg names itself,
  # so the router hands each generate to that leg's own scripted queues.
  # Newest-first matching keeps a later leg's marker ahead of the earlier
  # markers its own transcript nests.
  class PromptRoutedModel
    def initialize(routes)
      @routes = routes
    end

    def generate(stage:, system:, prompt:)
      matched = @routes.find { |marker, _model| prompt.include?(marker) }
      raise KeyError, "no scripted leg for #{stage}" unless matched

      matched.last.generate(stage:, system:, prompt:)
    end
  end

  def test_canonical_cross_surface_composition_story
    fixture = Fixture.new(model_factory: ->(_options) { build_routes },
                          admission_mode: :pairing,
                          approval_ask: { timeout_s: 86_400, on_timeout: :park })
    drive_story(fixture)
  ensure
    fixture&.close
  end

  private

  def build_routes
    shared = Fixture.model_factory(
      plan: [READ_PLAN], review: [Fixture::ACCEPTED_REVIEW],
      verify: [Fixture::VERIFY_OK.first]
    ).call(nil)
    crash = Fixture.crashing_factory(
      after: :plan, plan: [READ_PLAN], review: [Fixture::ACCEPTED_REVIEW],
      verify: [Fixture::VERIFY_OK.first]
    ).call(nil)
    slow = slow_park_leg_model
    PromptRoutedModel.new(
      [[MARKER_FINAL, shared], [MARKER_CRASH, crash], [MARKER_SLOW, slow],
       [MARKER_OPS_B, shared], [MARKER_OPS_A, shared],
       [MARKER_ONE_B, shared], [MARKER_ONE_A, shared]]
    )
  end

  def slow_park_leg_model
    inspect_step = { 'id' => 'look', 'purpose' => 'read the note', 'tool' => 'read_file',
                     'arguments' => { 'path' => 'note.txt' },
                     'verification' => 'the output is present' }
    edit_step = { 'id' => 'edit', 'purpose' => 'apply the exact replacement', 'tool' => 'apply_patch',
                  'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                  'verification' => 'the receipt reports the new digest' }
    Fixture.model_factory(
      plan: [
        { 'goal' => 'inspect then fix note.txt', 'done_when' => ['note.txt reads fixed'],
          'steps' => [inspect_step] },
        { 'goal' => 'fix note.txt', 'done_when' => ['note.txt reads fixed'],
          'steps' => [edit_step] }
      ],
      review: [Fixture::ACCEPTED_REVIEW, Fixture::ACCEPTED_REVIEW],
      verify: [{ 'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt'] }]
    ).call(nil)
  end

  def drive_story(fixture)
    @clock = fixture.now
    telegram_legs, cli_legs = pair_both_conversations(fixture)
    slow_turn_cancel_timeline(fixture)
    crash_recovery_and_delivery_faults(fixture)
    cross_cutting_oracle_score(fixture, telegram_legs:, cli_legs:)
  end

  # The fixture freezes `now`, which would stamp every gateway append with
  # one identical millisecond; outbox ties then order arbitrarily and the
  # oracles would read a shuffled story. Each submission ticks the clock so
  # appended facts keep true chronology.
  def submit_update(fixture, update)
    @clock += 1.7
    fixture.submit([update], now: @clock)
  end

  # Phase 1: first contact -> pairing approval -> admitted turn on BOTH
  # conversations, plus one durable-CLI leg each for cross-surface parity.
  def pair_both_conversations(fixture)
    code_a = pairing_code(fixture, 101, USER_A, CONVERSATION_A)
    approve_pairing(fixture, code_a, USER_A, CONVERSATION_A)
    paired_a = fixture.store.bindings(surface_id: SURFACE_ID).select do |row|
      row['status'] == 'active' && row['correspondent_id'] == "telegram:user:#{USER_A}"
    end

    assert_equal [CONVERSATION_A], paired_a.map { |row| row['conversation_id'] },
                 'approving one code must bind exactly its own conversation'

    code_b = pairing_code(fixture, 102, USER_B, CONVERSATION_B)
    pending_b = fixture.store.pairing_challenges(status: 'pending', now: fixture.now)
                             .find { |row| row.fetch('conversation_id') == CONVERSATION_B }

    assert pending_b, 'conversation B challenge missing'
    refute PairingChallenge.verify?(
      challenge: code_a, digest: pending_b.fetch('challenge_digest'),
      surface_id: SURFACE_ID, correspondent_id: pending_b.fetch('correspondent_id'),
      conversation_id: CONVERSATION_B
    ), 'conversation A code must not pair conversation B'
    approve_pairing(fixture, code_b, USER_B, CONVERSATION_B)

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

  def pairing_code(fixture, update_id, user_id, conversation_id)
    reply = control_reply(fixture, raw_update(update_id, 'Hello, requesting access.',
                                              user_id:, conversation_id:))

    assert reply, 'first contact produced no pairing reply'
    assert reply['text'].start_with?(Gateway::PAIRING_PENDING_REPLY), reply['text']
    reply['text'].delete_prefix(Gateway::PAIRING_PENDING_REPLY)
  end

  def approve_pairing(fixture, code, user_id, conversation_id)
    row = fixture.store.pairing_challenges(status: 'pending', now: fixture.now).find do |candidate|
      candidate.fetch('correspondent_id') == "telegram:user:#{user_id}" &&
        candidate.fetch('conversation_id') == conversation_id &&
        PairingChallenge.verify?(
          challenge: code, digest: candidate.fetch('challenge_digest'),
          surface_id: SURFACE_ID, correspondent_id: candidate.fetch('correspondent_id'),
          conversation_id:
        )
    end

    assert row, "no pending challenge matches the code for #{conversation_id}"
    binding_wire = Tamoz::Comms::Binding.new(
      surface_id: SURFACE_ID, surface_revision: Fixture::SURFACE_REVISION,
      correspondent_id: row.fetch('correspondent_id'), conversation_id:,
      bound_at: fixture.now, bound_by: 'operator:composition'
    ).wire

    assert_equal :approved, fixture.store.approve_pairing(
      challenge_digest: row.fetch('challenge_digest'), binding_wire: binding_wire, now: fixture.now
    )
  end

  def admitted_telegram_turn(fixture, conversation, user_id, update_id, text)
    baseline = delivery_baseline(fixture)
    submit_update(fixture, raw_update(update_id, text, user_id:, conversation_id: conversation))
    work_until_terminal(fixture, conversation)
    drain_all(fixture)
    reference = Lifecycle::RequestRef.for(fixture.request_ids_for(conversation).last)
    accepted_text = fixture.outbox.find do |row|
      row['conversation_id'] == conversation && row['kind'] == 'accepted'
    end&.fetch('text')

    assert accepted_text.to_s.include?(reference), 'acknowledgement lacks the request reference'
    leg_snapshot(fixture, conversation:, request_id: fixture.request_ids_for(conversation).last,
                        delivery_baseline: baseline)
  end

  def admitted_cli_turn(fixture, conversation, purpose, task)
    thread = fixture.thread_for(conversation)
    baseline = delivery_baseline(fixture)
    request_id = fixture.submit_cli_task(thread_id: thread, purpose:, task:)
    work_until_terminal(fixture, conversation)
    drain_all(fixture)
    leg_snapshot(fixture, conversation:, request_id:, delivery_baseline: baseline)
  end

  # Phase 2: conversation A's slow turn parks waiting on an approval ask,
  # /cancel lands mid-flight, and the ref-addressed /status renders the clean
  # stop timeline from durable facts alone.
  def slow_turn_cancel_timeline(fixture)
    conversation = CONVERSATION_A
    thread = fixture.thread_for(conversation)
    submit_update(fixture, raw_update(130, "Fix note.txt to say fixed. #{MARKER_SLOW}",
                                      user_id: USER_A, conversation_id: CONVERSATION_A))
    fixture.work

    assert_equal :paused, fixture.view(thread)&.status, 'slow turn never parked on the approval ask'
    waiting_card = Oracles.milestone_rows(fixture.snapshot(conversations: [conversation]))
                          .any? { |row| row.dig('milestone_facts', 'phase') == 'waiting' }

    assert waiting_card, 'no waiting milestone was projected for the parked turn'

    request_id = fixture.request_ids_for(conversation).last
    reference = Lifecycle::RequestRef.for(request_id)
    cancel_reply = control_reply(fixture, raw_update(131, '/cancel', user_id: USER_A,
                                                     conversation_id: CONVERSATION_A))

    # The accepted /cancel reply binds the target reference (c69b55e card copy).
    assert_equal "Cancellation requested for #{reference}.", cancel_reply&.fetch('text')

    observed = fixture.store.mark_cancellation_observed(thread_id: thread, now: @clock)

    assert_equal :observed, observed

    timeline = cancellation_timeline(fixture, conversation, request_id)

    assert timeline[:requested_present], 'requested stamp missing'
    assert timeline[:observed_present], 'observed stamp missing'
    assert timeline[:requested_le_observed], 'observation precedes the request'
    assert_equal 'terminal', timeline[:state]
    assert_equal 'stopped', timeline[:terminal_word]

    status_reply = control_reply(fixture, raw_update(132, "/status #{reference}",
                                                     user_id: USER_A, conversation_id: CONVERSATION_A))
    text = status_reply&.fetch('text').to_s

    assert text.include?(reference), text
    assert text.include?('Terminal: stopped at the cancellation boundary.'), text
    refute text.include?('completed before the cancellation took effect'), text
    drain_all(fixture)
  end

  # Phase 3: conversation B crashes mid-plan, recovers on a fresh worker,
  # replays a duplicate Telegram update harmlessly, refuses an oversized
  # update then admits a valid one, and lands one send ambiguous — unknown,
  # never re-sent.
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
    conversation = CONVERSATION_B
    # The envelope bound and the default intake limit coincide at 8192, so a
    # revision bump tightening the DEPLOYED limit is what makes admission's
    # typed oversize refusal reachable through the real Normalizer seam.
    tighten_surface_limit(fixture, max_inbound_bytes: 4096)
    requests_before = fixture.request_ids_for(conversation).length
    refusal = control_reply(fixture, raw_update(150, 'x' * 6000, user_id: USER_B,
                                                conversation_id: conversation))

    assert_equal "That message exceeds this channel's size limit.", refusal&.fetch('text')
    assert_equal requests_before, fixture.request_ids_for(conversation).length,
                 'oversized update enqueued work'

    submit_update(fixture, raw_update(160, "Final question for the channel. #{MARKER_FINAL}",
                                      user_id: USER_B, conversation_id: conversation))

    assert_equal requests_before + 1, fixture.request_ids_for(conversation).length,
                 'valid successor turn was not admitted'
    drain_all(fixture)
    work_until_terminal(fixture, conversation, worker: fixture.fresh_worker)
  end

  def tighten_surface_limit(fixture, max_inbound_bytes:)
    descriptor = Tamoz::Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: Fixture::SURFACE_REVISION + 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: Fixture::BOT_ID, bot_username: Fixture::BOT_USERNAME },
      admission: { direct: 'pairing', correspondents: [] },
      threading: 'conversation', profile_id: Fixture::PROFILE_ID,
      profile_digest: fixture.runtime.profile(Fixture::PROFILE_ID).canonical_digest,
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes:, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 500, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )

    assert_equal :deployed, fixture.store.deploy_surface(descriptor.wire, now: fixture.now)
  end

  def ambiguous_send_never_resent(fixture)
    pending = fixture.outbox(statuses: %w[pending])
    answer_index = pending.index { |row| row['kind'] == 'answer' }

    assert answer_index, 'no pending terminal answer to fault'
    fixture.transport.send_script = Array.new(answer_index) +
                                    [AmbiguousDeliveryError.new('timeout after send')]
    fixture.drain

    unknown = fixture.outbox(statuses: %w[unknown])

    assert_equal 1, unknown.length, 'exactly one send must land unknown'
    assert_equal 'answer', unknown.first.fetch('kind')
    assert_nil unknown.first['receipt'], 'an ambiguous send must carry no receipt'

    sends_before = fixture.transport.sends.length
    fixture.drain

    assert_equal sends_before, fixture.transport.sends.length, 'unknown delivery was re-sent'
    assert_equal 1, fixture.outbox(statuses: %w[unknown]).length

    view = fixture.view(fixture.thread_for(CONVERSATION_B))

    assert_equal :completed, view&.status, 'task truth must survive the delivery ambiguity'
  end

  # Phase 4: cross-cutting invariants scored by the same oracles the B0
  # scenarios use — meaning-level CLI/Telegram parity, confirmed-deliveries
  # history, reference isolation, and journal-backed milestones.
  def cross_cutting_oracle_score(fixture, telegram_legs:, cli_legs:)
    facts = fixture.snapshot(conversations: [CONVERSATION_A, CONVERSATION_B])
                   .merge('telegram_legs' => telegram_legs, 'cli_legs' => cli_legs)

    parity = Oracles.core_parity_document(facts)

    assert_equal 1, parity.fetch('score'), parity.fetch('compared')
    Oracles::CORE_PARITY_FACTS.each do |fact|
      assert_equal 1, parity.dig('compared', fact), "#{fact} must agree across surfaces"
    end

    [CONVERSATION_A, CONVERSATION_B].each do |conversation|
      assert_equal Oracles::PASS, Oracles.context_inclusion(facts, conversation),
                   "#{conversation} history must hold only its own confirmed deliveries"
      assert_equal Oracles::PASS, Oracles.first_reference_stable(facts, conversation)
    end

    cards = Oracles.milestone_rows(facts)

    refute_empty cards
    assert cards.all? { |row| row['journaled'] == 0 }, 'milestone rows must be journaled=0'
    assistants = facts['history'].values.flatten.select { |entry| entry['role'] == 'assistant' }
    leaked = cards.any? do |row|
      assistants.any? { |entry| entry['text'].to_s.include?(row.dig('milestone_facts', 'phase')) }
    end

    refute leaked, 'a milestone card leaked into conversation history'
    phases = cards.map { |row| row.dig('milestone_facts', 'phase') }

    assert_includes phases, 'waiting', 'the parked slow turn never projected waiting'
    assert_includes phases, 'recovered', 'the fresh worker never projected recovery'

    ref_a = Lifecycle::RequestRef.for(fixture.request_ids_for(CONVERSATION_A).first)
    ref_b = Lifecycle::RequestRef.for(fixture.request_ids_for(CONVERSATION_B).first)

    assert_equal :unknown_ref, fixture.request_status(CONVERSATION_A, ref_b)
    assert_equal :unknown_ref, fixture.request_status(CONVERSATION_B, ref_a)

    foreign_reply = control_reply(fixture, raw_update(170, "/status #{ref_b}", user_id: USER_A,
                                                      conversation_id: CONVERSATION_A))

    assert_equal Gateway::UNKNOWN_REF_REPLY, foreign_reply&.fetch('text')
    drain_all(fixture)

    sends = fixture.transport.sends.group_by { |send| send[:conversation_id] }.keys.sort

    assert_equal [CONVERSATION_A, CONVERSATION_B].sort, sends
    own_references = Hash.new([])
    facts['requests'].each do |row|
      own_references[row['conversation_id']] += [row.fetch('request_ref')]
    end
    (telegram_legs + cli_legs).each do |leg|
      own_references[leg.fetch('conversation_id')] += [leg.fetch('reference')]
    end
    facts['outbox'].each do |row|
      reference = row.dig('milestone_facts', 'request_ref')
      next unless reference

      assert_includes own_references[row['conversation_id']], reference,
                      'a milestone card crossed conversations'
    end

    answers_b = facts['outbox'].select do |row|
      row['conversation_id'] == CONVERSATION_B && row['kind'] == 'answer'
    end

    assert_equal 4, answers_b.length
    assert_equal 1, answers_b.count { |row| row['status'] == 'unknown' }
    assert_equal 3, Oracles.confirmed_answer_texts(facts, CONVERSATION_B).length

    assert_equal [['request', 'accepted']], Oracles.dispositions(facts, 140)
    assert_equal [['rejected', 'inbound_too_large']], Oracles.dispositions(facts, 150)

    effect_keys = fixture.effect_census.map { |row| row[:effect_key] }

    assert_equal effect_keys.uniq, effect_keys, 'recovery duplicated an effect'
    assert Oracles.c8_history_clean?(facts, CONVERSATION_A), 'a cancellation fact entered history'
  end

  def raw_update(update_id, text, user_id:, conversation_id:)
    { 'update_id' => update_id,
      'message' => { 'message_id' => update_id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => conversation_id.delete_prefix('telegram:chat:').to_i,
                                 'type' => 'private' },
                     'from' => { 'id' => user_id }, 'text' => text } }
  end

  def control_reply(fixture, update)
    before = fixture.outbox.map { |row| row.fetch('delivery_id') }
    submit_update(fixture, update)
    fixture.outbox
           .reject { |row| before.include?(row.fetch('delivery_id')) }
           .find { |row| row['kind'] == 'control' }
  end

  def terminal_view?(fixture, conversation)
    view = fixture.view(fixture.thread_for(conversation))

    view && %i[completed failed blocked].include?(view.status)
  end

  def work_until_terminal(fixture, conversation, worker: nil)
    8.times do
      worker ? worker.poll_once : fixture.work
      break if terminal_view?(fixture, conversation)
    end

    assert terminal_view?(fixture, conversation), 'turn never reached a terminal view'
  end

  def drain_all(fixture)
    4.times do
      break if fixture.outbox(statuses: %w[pending]).empty?

      fixture.drain
    end

    assert_empty fixture.outbox(statuses: %w[pending]), 'outbox never quiesced'
  end

  def delivery_baseline(fixture)
    fixture.outbox.map { |row| row.fetch('delivery_id') }
  end

  def leg_snapshot(fixture, conversation:, request_id:, delivery_baseline:)
    thread = fixture.thread_for(conversation)
    row = fixture.request_row(thread, request_id)
    {
      'conversation_id' => conversation,
      'thread_id' => thread,
      'request_id' => request_id,
      'reference' => Lifecycle::RequestRef.for(request_id),
      'request_status' => row && row.status.to_s,
      'request_row_present' => !row.nil?,
      'terminal_reason' => fixture.view(thread)&.terminal&.dig('reason'),
      'delivery_state' => leg_delivery_state(fixture, delivery_baseline)
    }.compact
  end

  def leg_delivery_state(fixture, baseline_ids)
    fresh = fixture.outbox
                   .reject { |row| baseline_ids.include?(row.fetch('delivery_id')) }
                   .select { |row| Oracles::TERMINAL_KINDS.include?(row['kind']) }
    return 'none' if fresh.empty?

    statuses = fresh.map { |row| row['status'] }.uniq
    statuses.length == 1 ? statuses.first : 'mixed'
  end

  def cancellation_timeline(fixture, conversation, request_id)
    reference = Lifecycle::RequestRef.for(request_id)
    resolved = fixture.request_status(conversation, reference)
    document = resolved.is_a?(Hash) ? resolved.fetch('cancellation', {}) : {}
    stamp = fixture.cancellation_stamp_rows.find { |row| row.fetch('request_id') == request_id } || {}
    requested = stamp['requested_at_ms']
    observed = stamp['observed_at_ms']
    {
      reference:, requested_present: !requested.nil?, observed_present: !observed.nil?,
      requested_le_observed: requested && observed ? requested <= observed : false,
      state: document['state'], terminal_word: document['terminal']
    }
  end
end
