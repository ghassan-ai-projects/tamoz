# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# rubocop:disable Minitest/MultipleAssertions
class TalkHubTest < Minitest::Test
  Talk = Tamoz::Talk
  Comms = Tamoz::Comms
  TOKEN = 'a' * 32

  LIMITS = { max_inbound_bytes: 8192, max_open_requests: 50, max_denial_prompts_per_request: 4, outbox_capacity: 500,
             control_capacity: 50, per_chat_messages_per_s: 20.0, global_messages_per_s: 50.0 }.freeze

  def descriptor
    Comms::SurfaceDescriptor.build(
      surface_id: 'talk', revision: 1, kind: 'talk',
      transport: { mode: 'long_poll', credential_ref: { kind: 'env', name: 'TAMOZ_TALK_TOKEN' }, poll_timeout_s: 10,
                   batch: 50, max_response_bytes: nil, port: 8787 },
      identity: { expected_bot_id: 123_456_789_012 }, admission: { direct: 'allowlist', correspondents: ['talk:user:1'] },
      threading: 'conversation', profile_id: 'talk', approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }, limits: LIMITS
    )
  end

  def delivery(text, kind: 'answer', part_index: 0, part_count: 1, markup: nil, operation: 'send_message',
               reply_to: nil)
    Comms::Delivery.build(conversation_id: 'talk:chat:1', kind:, text:, render_version: 1,
                          content_digest: Digest::SHA256.hexdigest(text), part_index:, part_count:, markup:,
                          operation:, reply_to:)
  end

  def test_a_short_token_is_refused
    assert_raises(ArgumentError) { Talk::Hub.new(descriptor:, token: 'a' * 31, floor: 0) }
  end

  def test_a_final_reply_ends_the_working_state_and_a_control_notice_does_not
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    hub.transport.signal(:typing, conversation_id: 'talk:chat:1')
    hub.deliver(delivery('Heard: «pond 7»', kind: 'control'))

    refute_nil hub.log.since(after: 0, epoch: nil, timeout_s: 0)['working']
    hub.deliver(delivery('Pond 7 is fine.'))

    assert_nil hub.log.since(after: 0, epoch: nil, timeout_s: 0)['working']
  end

  def test_a_seed_row_without_a_receipt_is_skipped
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    row = delivery('Lost.').wire.merge('receipt' => nil, 'journaled' => 1)
    hub.seed([row])

    assert_empty hub.log.since(after: 0, epoch: nil, timeout_s: 0)['events']
  end

  def test_both_transports_share_one_hub_so_a_drainer_delivery_reaches_the_page
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    poller = hub.transport
    drainer = hub.transport
    receipt = drainer.deliver(delivery('Pond 7 is fine.'))
    page = hub.log.since(after: 0, epoch: nil, timeout_s: 0)

    refute_same poller, drainer
    assert_equal([receipt.fetch('message_id')], page['events'].map { |event| event['message_id'] })
    assert_equal({ 'id' => 123_456_789_012 }, poller.authenticate(nil, nil))
  end

  def test_only_the_first_part_of_a_spoken_kind_is_spoken
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0, synthesize: ->(text) { "ID3#{text}".b })
    first = hub.deliver(delivery('Part one.', part_count: 2))
    second = hub.deliver(delivery('Part two.', part_index: 1, part_count: 2))
    heard = hub.deliver(delivery('Heard: «pond 7»', kind: 'control'))

    assert_equal "ID3Part one. #{Tamoz::Core::SpokenText::REST}", hub.speaker.speech(first.fetch('message_id'))
    assert_equal :not_spoken, hub.speaker.speech(second.fetch('message_id'))
    assert_equal :not_spoken, hub.speaker.speech(heard.fetch('message_id'))
    spoken = hub.log.since(after: 0, epoch: nil, timeout_s: 0)['events'].map { |event| event['spoken'] }

    assert_equal [true, false, false], spoken
  end

  def test_an_approval_card_carries_its_reference_and_an_edit_keeps_the_message_id
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    card = hub.deliver(delivery('Approve the change?', kind: 'approval_request',
                                                       markup: JSON.generate('reference' => 'abc', 'actions' => %w[approve deny])))
    edit = hub.deliver(delivery('Approved.', kind: 'control', operation: 'edit_message',
                                             reply_to: card.fetch('message_id')))
    events = hub.log.since(after: 0, epoch: nil, timeout_s: 0)['events']

    assert_equal [%w[approve deny], 'abc'], events.first.values_at('actions', 'reference')
    assert_equal card.fetch('message_id'), edit.fetch('message_id')
    assert_equal card.fetch('message_id'), events.last['replaces']
  end

  def test_a_seeded_card_keeps_its_original_id_and_new_ids_come_after_it
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    old_id = (Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) * 2)
    card = delivery('Approve?', kind: 'approval_request', markup: JSON.generate('reference' => 'r1'))
    hub.seed([card.wire.merge('journaled' => 1, 'receipt' => JSON.generate('message_id' => old_id))])
    fresh = hub.deliver(delivery('New.'))

    assert_equal old_id, hub.log.message(old_id)['message_id']
    assert_operator fresh.fetch('message_id'), :>, old_id
  end

  def test_the_transport_hands_out_held_audio_and_maps_signals
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0)
    transport = hub.transport

    assert_raises(Comms::TransientTransportError) { transport.fetch_attachment('talk-1', max_bytes: 10) }
    assert_equal :typing, transport.signal(:typing, conversation_id: 'talk:chat:1')
    assert_equal :acked, transport.signal(:ack, callback_query_id: '1', text: 'Approved')
    assert_equal :unsupported, transport.signal(:record_voice)
    assert hub.log.since(after: 0, epoch: nil, timeout_s: 0)['working']
  end

  def test_a_listening_page_gets_speech_prefetched_once
    calls = Queue.new
    hub = Talk::Hub.new(descriptor:, token: TOKEN, floor: 0, synthesize: lambda { |text|
      calls << text
      "ID3#{text}".b
    })
    hub.log.since(after: 0, epoch: nil, timeout_s: 0, speech: true)
    receipt = hub.deliver(delivery('Pond 7 is fine.'))
    sleep 0.01 until calls.size == 1

    assert_equal 'ID3Pond 7 is fine.', hub.speaker.speech(receipt.fetch('message_id'))
    assert_equal 1, calls.size
  end
end
# rubocop:enable Minitest/MultipleAssertions
