# frozen_string_literal: true

require 'tamoz/evals/benchmark/openclaw_comms_oracles'
require_relative 'canonical_composition_progress'

module CanonicalCompositionSteps
  include CanonicalCompositionProgress

  Gateway = Tamoz::Comms::Gateway
  PairingChallenge = Tamoz::Comms::PairingChallenge
  AmbiguousDeliveryError = Tamoz::Comms::AmbiguousDeliveryError

  private

  # The fixture freezes `now`, which would stamp every gateway append with
  # one identical millisecond; outbox ties then order arbitrarily and the
  # oracles would read a shuffled story. Each submission ticks the clock so
  # appended facts keep true chronology.
  def submit_update(fixture, update)
    @clock += 1.7
    fixture.submit([update], now: @clock)
  end

  def pairing_code(fixture, update_id, user_id, conversation_id)
    reply = control_reply(fixture, raw_update(update_id, 'Hello, requesting access.',
                                              user_id:, conversation_id:))

    assert reply, 'first contact produced no pairing reply'
    pending = reply['text'].start_with?(Gateway::PAIRING_PENDING_REPLY)

    assert pending, "reply: #{reply['text']}"
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

  def tighten_surface_limit(fixture, max_inbound_bytes:)
    descriptor = Tamoz::Comms::SurfaceDescriptor.build(
      kind: 'telegram',
      surface_id: SURFACE_ID, revision: Fixture::SURFACE_REVISION + 1,
      transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { stream_id: "telegram:bot:#{Fixture::BOT_ID}" }, settings: { bot_username: Fixture::BOT_USERNAME },
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
end
