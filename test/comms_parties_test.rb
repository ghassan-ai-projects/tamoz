# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions
class CommsPartiesTest < Minitest::Test
  Comms = Tamoz::Comms

  LIMITS = { max_inbound_bytes: 8192, max_open_requests: 50, max_denial_prompts_per_request: 4, outbox_capacity: 500,
             control_capacity: 50, per_chat_messages_per_s: 1.0, global_messages_per_s: 25.0 }.freeze

  def telegram_descriptor
    Comms::SurfaceDescriptor.build(
      kind: 'telegram',
      surface_id: 'telegram', revision: 3,
      transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 10, batch: 50, max_response_bytes: nil },
      identity: { stream_id: 'telegram:bot:8724435334' }, settings: { bot_username: 'tamoz_bot' },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:4242'] }, threading: 'conversation',
      profile_id: 'telegram', profile_digest: "sha256:#{'a' * 64}", approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }, limits: LIMITS
    )
  end

  def talk_descriptor(port: 8787, hosts: ['mac.tail.ts.net'])
    Comms::SurfaceDescriptor.build(
      surface_id: 'talk', revision: 1, kind: 'talk',
      transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TALK_TOKEN' },
                   poll_timeout_s: 10, batch: 50, max_response_bytes: nil },
      settings: { port:, allow_hosts: hosts },
      identity: { stream_id: 'talk:page' },
      admission: { direct: 'allowlist', correspondents: ['talk:user:1'] }, threading: 'conversation',
      profile_id: 'talk', approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }, limits: LIMITS
    )
  end

  def envelope(correspondent:, conversation:, surface_id: 'talk')
    Comms::InboundEnvelope.new(
      surface_id:, surface_revision: 1, update_id: 1, raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: correspondent, conversation_id: conversation, text: 'hello'
    ).wire
  end

  # Thread and decision ids keep their digests; the prefix is the kind's name and the descriptor carries a stream id.
  def test_telegram_ids_are_pinned
    assert_equal 'telegram.telegram.5749c9dc3be7bd32', Comms::Admission.thread_id('telegram', 'telegram:chat:4242')
    assert_equal 'telegram.telegram.64c1a2390a187a38',
                 Comms::Admission.thread_id('telegram', 'telegram:chat:4242', generation: 1)
    assert_equal '096f5b88c7047e35ba757f22292aaf69a2a8c9e72b4abe45db759a0030b87893',
                 telegram_descriptor.definition_digest
    decision = Comms::DecisionRecord.build(
      thread_id: 'telegram.telegram.0123456789abcdef', occurrence_id: 'occ-1', interrupts: [], interrupt_digest: 'b' * 64,
      direction: 'approve', actor_kind: 'telegram_user', actor_id: 'telegram:user:4242', source: 'telegram',
      decided_at: Time.utc(2026, 10, 9, 12), ttl_s: 900
    )

    assert_equal 'fa4ad5cae65235828f63c1461da2b40e4152573ab8279f585f061a725eef4093', decision.decision_id
    binding = Comms::Binding.new(surface_id: 'telegram', surface_revision: 3, correspondent_id: 'telegram:user:4242',
                                 conversation_id: 'telegram:chat:4242', bound_at: Time.utc(2026, 10, 9, 12),
                                 bound_by: 'operator')

    assert_equal({ 'surface_id' => 'telegram', 'surface_revision' => 3, 'correspondent_id' => 'telegram:user:4242',
                   'conversation_id' => 'telegram:chat:4242', 'status' => 'active',
                   'bound_at' => '2026-10-09T12:00:00.000000Z', 'bound_by' => 'operator', 'version' => 1,
                   'revocation_reason' => nil }, binding.wire)
  end

  def test_a_talk_conversation_gets_its_own_thread_prefix_on_the_same_digest
    telegram = Comms::Admission.thread_id('s', 'telegram:chat:1')
    talk = Comms::Admission.thread_id('s', 'talk:chat:1')

    assert_match(/\Atalk\.s\.\h{16}\z/, talk)
    refute_equal telegram.split('.').last, talk.split('.').last
    assert_equal 'talk.talk.59499c31359a3f5f', Comms::Admission.thread_id('talk', 'talk:chat:1')
    assert_raises(Comms::ValidationError) { Comms::Admission.thread_id('s', 'talk:room:1') }
  end

  def test_a_party_must_belong_to_its_surfaces_kind
    talk = talk_descriptor
    own = Comms::Admission.decide(envelope(correspondent: 'talk:user:1', conversation: 'talk:chat:1'), surface: talk)
    foreign = Comms::Admission.decide(envelope(correspondent: 'telegram:user:1', conversation: 'telegram:chat:1'),
                                      surface: talk)
    supergroup = Comms::Admission.decide(envelope(correspondent: 'telegram:user:1',
                                                  conversation: 'telegram:supergroup:-1001234567890',
                                                  surface_id: 'telegram'), surface: telegram_descriptor)

    assert_equal :group_chat, supergroup.reason
    %w[cli:user:1 os:chat:1].each { |id| assert_nil Comms::Parties.parse(id), id }
    mixed = Comms::Admission.decide(envelope(correspondent: 'talk:user:1', conversation: 'telegram:chat:1'),
                                    surface: talk)
    stray_user = Comms::Admission.decide(envelope(correspondent: 'telegram:user:1', conversation: 'talk:chat:1'),
                                         surface: talk)
    reverse = Comms::Admission.decide(envelope(correspondent: 'talk:user:1', conversation: 'talk:chat:1',
                                               surface_id: 'telegram'), surface: telegram_descriptor)

    assert_equal :request, own.disposition
    assert_match(/\Atalk\./, own.thread_id)
    [foreign, mixed, stray_user, reverse].each do |decision|
      assert_equal %i[rejected party_kind_mismatch], [decision.disposition, decision.reason]
    end
  end

  def test_only_chats_bind_while_telegram_groups_stay_admissible_to_be_refused
    bound_at = Time.utc(2026, 10, 9)
    Comms::Binding.new(surface_id: 'talk', surface_revision: 1, correspondent_id: 'talk:user:1',
                       conversation_id: 'talk:chat:1', bound_at:, bound_by: 'operator')
    assert_raises(Comms::ValidationError) do
      Comms::Binding.new(surface_id: 't', surface_revision: 1, correspondent_id: 'telegram:user:1',
                         conversation_id: 'telegram:group:1', bound_at:, bound_by: 'operator')
    end
    assert_raises(Comms::ValidationError) do
      Comms::Binding.new(surface_id: 't', surface_revision: 1, correspondent_id: 'talk:user:1',
                         conversation_id: 'telegram:chat:1', bound_at:, bound_by: 'operator')
    end
    group = Comms::Admission.decide(envelope(correspondent: 'telegram:user:1', conversation: 'telegram:group:9',
                                             surface_id: 'telegram'), surface: telegram_descriptor)

    assert_equal :group_chat, group.reason
    supergroup = Comms::Admission.decide(envelope(correspondent: 'telegram:user:1',
                                                  conversation: 'telegram:supergroup:-1001234567890',
                                                  surface_id: 'telegram'), surface: telegram_descriptor)

    assert_equal :group_chat, supergroup.reason
    %w[cli:user:1 os:chat:1].each { |id| assert_nil Comms::Parties.parse(id), id }
    mixed = Comms::Admission.decide(envelope(correspondent: 'loopback:user:1', conversation: 'telegram:chat:1',
                                             surface_id: 'telegram'), surface: telegram_descriptor)

    assert_equal :party_kind_mismatch, mixed.reason
    assert_raises(Comms::ValidationError) { envelope(correspondent: 'talk:person:1', conversation: 'talk:chat:1') }
  end

  def test_a_talk_descriptor_needs_a_port_and_bounded_hosts
    talk = Tamoz::Talk::Channel.new

    assert_equal 'talk', talk_descriptor.kind
    assert_raises(Comms::ValidationError) { talk.validate!(talk_descriptor(port: nil)) }
    assert_raises(Comms::ValidationError) { talk.validate!(talk_descriptor(port: 70_000)) }
    assert_raises(Comms::ValidationError) { talk.validate!(talk_descriptor(hosts: ['x' * 254])) }
    assert_raises(Comms::ValidationError) { talk.validate!(talk_descriptor(hosts: 'mac.tail.ts.net')) }
    ['*', 'mac.tail.ts.net:443', 'two words', ''].each do |host|
      assert_raises(Comms::ValidationError, host) { talk.validate!(talk_descriptor(hosts: [host])) }
    end
    assert_raises(Comms::ValidationError) { talk.validate!(talk_descriptor(hosts: %w[a.b a.b])) }
  end

  def test_talk_decisions_carry_their_own_actor_and_source
    record = Comms::DecisionRecord.build(
      thread_id: 'talk.talk.0123456789abcdef', occurrence_id: 'occ-1', interrupts: [], interrupt_digest: 'b' * 64,
      direction: 'deny', actor_kind: 'talk_user', actor_id: 'talk:user:1', source: 'talk',
      decided_at: Time.utc(2026, 10, 9, 12), ttl_s: 900
    )

    assert_equal %w[talk_user talk], [record.actor_kind, record.source]
  end
end
# rubocop:enable Minitest/MultipleAssertions
