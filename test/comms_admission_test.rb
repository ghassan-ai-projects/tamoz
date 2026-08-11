# frozen_string_literal: true

require_relative 'test_helper'

# Slice D (COMMS_TELEGRAM_PLAN §3) — private-chat admission (design §5): the
# pure decision function over envelope + surface + binding + route, plus the
# hashed pairing challenge. Every disposition is deterministic; callbacks are
# decisions (v1 deny-only), never requests; group chats and unknown commands
# never become model input.
# rubocop:disable Minitest/MultipleAssertions
class CommsAdmissionTest < Minitest::Test
  Comms = Tamoz::Comms

  def surface(direct: 'allowlist', approvals: 'deny_only')
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990 },
      admission: { direct:, correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: approvals, prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def envelope(kind: 'text', text: 'hello', conversation: 'telegram:chat:22222222',
               correspondent: 'telegram:user:11111111')
    Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id: 1,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind:,
      correspondent_id: correspondent, conversation_id: conversation,
      text:, observed_time: Time.utc(2026, 8, 10, 12, 0, 0)
    ).wire
  end

  def active_binding
    { 'status' => 'active', 'conversation_id' => 'telegram:chat:22222222' }
  end

  def test_an_active_binding_requests_a_turn_on_the_conversation_thread
    decision = Comms::Admission.decide(
      envelope, surface: surface, binding: active_binding,
                conversation: { 'thread_id' => 'tg.ops.abc', 'profile_id' => 'ops' }
    )

    assert_equal :request, decision.disposition
    assert_equal :bound, decision.reason
    assert_equal 'tg.ops.abc', decision.thread_id
  end

  def test_a_first_request_derives_the_deterministic_thread
    decision = Comms::Admission.decide(
      envelope, surface: surface, binding: active_binding, conversation: nil
    )

    assert_equal :request, decision.disposition
    assert_equal :first_request, decision.reason
    assert_match(/\Atg\.telegram-ops\.[0-9a-f]{16}\z/, decision.thread_id)
    assert_equal decision.thread_id,
                 Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
  end

  def test_an_unbound_sender_is_ignored_not_rejected
    decision = Comms::Admission.decide(envelope(correspondent: 'telegram:user:99999999'),
                                       surface: surface, binding: nil)

    assert_equal :ignored, decision.disposition
    assert_equal :unbound, decision.reason
  end

  # The allowlist is the admission (design §7): a listed id is admitted
  # WITHOUT a pairing binding — the binding records operator pairing, the
  # descriptor list records operator configuration.
  def test_an_allowlisted_sender_is_admitted_without_a_binding
    decision = Comms::Admission.decide(envelope, surface: surface, binding: nil, conversation: nil)

    assert_equal :request, decision.disposition
    refute_nil decision.thread_id
  end

  def test_a_disabled_surface_rejects_with_a_notice
    disabled = surface(direct: 'disabled')
    decision = Comms::Admission.decide(envelope, surface: disabled, binding: nil)

    assert_equal :rejected, decision.disposition
    assert_equal :surface_disabled, decision.reason
  end

  def test_group_chats_are_refused_in_v1
    %w[telegram:group:333 telegram:supergroup:444 telegram:channel:555].each do |conversation|
      decision = Comms::Admission.decide(
        envelope(conversation:), surface: surface, binding: active_binding
      )

      assert_equal :rejected, decision.disposition, conversation
      assert_equal :group_chat, decision.reason
    end
  end

  def test_a_known_command_is_a_control_disposition
    decision = Comms::Admission.decide(
      envelope(kind: 'command', text: '/help'), surface: surface, binding: active_binding
    )

    assert_equal :control, decision.disposition
    assert_equal :command, decision.reason
    assert_equal 'help', decision.command_intent.name
    assert_nil decision.command_intent.arguments
  end

  def test_an_unbound_command_is_ignored_before_command_parsing_can_have_effect
    decision = Comms::Admission.decide(
      envelope(kind: 'command', text: '/cancel', correspondent: 'telegram:user:99999999'),
      surface: surface, binding: nil
    )

    assert_equal :ignored, decision.disposition
    assert_equal :unbound, decision.reason
    assert_nil decision.command_intent
  end

  def test_an_unknown_slash_command_gets_a_typed_control_reply
    decision = Comms::Admission.decide(
      envelope(kind: 'command', text: '/eval rm -rf /'), surface: surface, binding: active_binding
    )

    assert_equal :control, decision.disposition
    assert_equal :unknown_command, decision.reason
    refute_nil decision.control_reply
  end

  def test_a_callback_is_a_decision_never_a_request
    decision = Comms::Admission.decide(
      envelope(kind: 'callback'), surface: surface, binding: active_binding
    )

    assert_equal :decision, decision.disposition
    assert_equal :callback, decision.reason
  end

  def test_membership_and_unsupported_updates_are_ignored
    %w[membership unsupported].each do |kind|
      decision = Comms::Admission.decide(envelope(kind:), surface: surface, binding: nil)

      assert_equal :ignored, decision.disposition, kind
      assert_equal :unsupported_kind, decision.reason
    end
  end

  def test_pairing_mode_waits_for_a_consumed_challenge
    pairing = surface(direct: 'pairing')
    decision = Comms::Admission.decide(envelope, surface: pairing, binding: nil)

    assert_equal :ignored, decision.disposition
    assert_equal :pairing_pending, decision.reason
  end

  def test_pairing_challenge_digest_binds_surface_correspondent_and_conversation
    challenge = Comms::PairingChallenge.build(
      surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222', ttl_s: 900,
      now: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert Comms::PairingChallenge.verify?(
      challenge: challenge.challenge, digest: challenge.digest,
      surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222'
    )
    refute Comms::PairingChallenge.verify?(
      challenge: challenge.challenge, digest: challenge.digest,
      surface_id: 'telegram-ops', correspondent_id: 'telegram:user:99999999',
      conversation_id: 'telegram:chat:22222222'
    ), 'a challenge copied to another user must not pair'
  end
end
# rubocop:enable Minitest/MultipleAssertions
