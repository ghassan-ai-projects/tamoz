# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_fixture_server'

# Slice F (COMMS_TELEGRAM_PLAN §3) — the tamoz-telegram transport driven
# against the in-memory fixture server (design §6.4 conformance): wrong
# credentials refuse, polls confirm the durable prefix remotely, a send
# timeout is genuinely ambiguous (never retried), throttling carries the
# server's authoritative retry_after, and updates normalize to typed
# envelopes.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
class TamozTelegramTransportTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_transport
    server = TelegramFixtureServer.new
    client = Tamoz::Telegram::Client.new('test-token', origin: server.url, read_timeout: 1.0)
    normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)
    transport = Tamoz::Telegram::Transport.new(client:, normalizer:)
    begin
      yield transport, server
    ensure
      server&.stop
    end
  end

  def update(id, chat_id: 222_222_22, user_id: 111_111_11, text: nil, chat_type: 'private')
    {
      'update_id' => id,
      'message' => {
        'message_id' => id,
        'date' => 1_752_700_800,
        'chat' => { 'id' => chat_id, 'type' => chat_type },
        'from' => { 'id' => user_id },
        'text' => text
      }
    }.compact
  end

  def test_authenticate_returns_the_surface_identity
    with_transport do |transport, server|
      server.script('getMe', body: { 'ok' => true, 'result' => { 'id' => 7_463_512_990,
                                                                 'username' => 'ops_bot' } }, times: 1)
      result = transport.authenticate(nil, nil)

      assert_equal 7_463_512_990, result.fetch('id')
      assert_equal 'ops_bot', result.fetch('username')
    end
  end

  def test_authenticate_refuses_a_wrong_token
    with_transport do |transport, server|
      server.script('getMe', status: 401, body: { 'ok' => false, 'description' => 'Unauthorized' }, times: 1)

      assert_raises(Comms::AuthenticationError) { transport.authenticate(nil, nil) }
    end
  end

  def test_poll_returns_normalized_envelopes_and_the_candidate_offset
    with_transport do |transport, server|
      server.script('getUpdates', body: {
        'ok' => true,
        'result' => [update(101, text: 'hello'), update(100, text: '/help')]
      }, times: 1)

      batch = transport.poll(next_offset: nil, limit: 50, timeout_s: 30)

      assert_equal 2, batch[:updates].length
      assert_equal 102, batch[:next_offset], 'candidate offset is one past the highest id'
      first = batch[:updates].first

      assert_equal 101, first.fetch('update_id')
      assert_equal 'text', first.fetch('kind')
      assert_equal 'telegram:user:11111111', first.fetch('correspondent_id')
      assert_equal 'telegram:chat:22222222', first.fetch('conversation_id')
      assert_equal 'command', batch[:updates].last.fetch('kind')
    end
  end

  def test_poll_passes_the_confirmed_offset_and_allowed_updates
    with_transport do |transport, server|
      server.script('getUpdates', body: { 'ok' => true, 'result' => [] }, times: 1)
      server.script('getUpdates', body: { 'ok' => true, 'result' => [] }, times: 1)

      transport.poll(next_offset: nil, limit: 50, timeout_s: 30)
      transport.poll(next_offset: 100, limit: 50, timeout_s: 30)

      calls = server.requests

      assert_equal 2, calls.length
      assert_equal %w[message callback_query my_chat_member],
                   JSON.parse(calls.first.fetch(:body)).fetch('allowed_updates')
      refute JSON.parse(calls.first.fetch(:body)).key?('offset')
      assert_equal 100, JSON.parse(calls.last.fetch(:body)).fetch('offset'),
                   'the confirmed offset must be supplied on the next poll'
    end
  end

  def test_poll_throttling_carries_the_authoritative_retry_after
    with_transport do |transport, server|
      server.script('getUpdates', status: 429,
                                  body: { 'ok' => false, 'parameters' => { 'retry_after' => 7 } }, times: 1)

      error = assert_raises(Comms::ThrottledError) { transport.poll(next_offset: nil, limit: 50, timeout_s: 30) }
      assert_equal 7, error.retry_after
    end
  end

  def test_poll_server_errors_are_transient_and_do_not_kill_the_gateway
    with_transport do |transport, server|
      server.script('getUpdates', status: 500, body: { 'ok' => false }, times: 1)

      assert_raises(Comms::TransientTransportError) do
        transport.poll(next_offset: nil, limit: 50, timeout_s: 30)
      end
    end
  end

  def test_deliver_send_message_returns_the_receipt
    with_transport do |transport, server|
      server.script('sendMessage', body: {
        'ok' => true,
        'result' => { 'message_id' => 42, 'date' => 1_752_700_800 }
      }, times: 1)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'hello',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'b' * 64
      )

      receipt = transport.deliver(delivery)

      assert_equal 42, receipt.fetch('message_id')
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, receipt.fetch('platform_time'))
    end
  end

  def test_deliver_edit_message_uses_edit_message_text
    with_transport do |transport, server|
      server.script('editMessageText', body: {
        'ok' => true,
        'result' => { 'message_id' => 42, 'date' => 1_752_700_800 }
      }, times: 1)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'control', text: 'updated',
        part_index: 0, part_count: 1, journaled: false, render_version: 1,
        content_digest: 'c' * 64, operation: 'edit_message'
      )

      assert_equal 42, transport.deliver(delivery).fetch('message_id')
    end
  end

  def test_a_send_timeout_is_ambiguous_never_retried
    with_transport do |transport, server|
      server.script('sendMessage', body: { 'ok' => true, 'result' => { 'message_id' => 1, 'date' => 1 } },
                                   times: 1, delay_s: 2.0)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'x',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'd' * 64
      )

      assert_raises(Comms::AmbiguousDeliveryError) { transport.deliver(delivery) }
    end
  end

  def test_send_server_errors_are_ambiguous_and_never_retried
    with_transport do |transport, server|
      server.script('sendMessage', status: 500, body: { 'ok' => false }, times: 1)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'x',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'e' * 64
      )

      assert_raises(Comms::AmbiguousDeliveryError) { transport.deliver(delivery) }
    end
  end

  # The mirror image of the send case: a read that times out observed nothing
  # and changed nothing, so it is typed TRANSIENT and the caller repeats it.
  # Typing it as ambiguous would say an effect may already have happened, and
  # a gateway that cannot tell the two apart either stalls or duplicates.
  def test_a_poll_timeout_is_transient_not_ambiguous
    with_transport do |transport, server|
      server.script('getUpdates', body: { 'ok' => true, 'result' => [] }, times: 1, delay_s: 2.0)

      error = assert_raises(Comms::TransientTransportError) do
        transport.poll(next_offset: nil, limit: 50, timeout_s: 0)
      end
      refute_kind_of Comms::AmbiguousDeliveryError, error
    end
  end

  # 409 is the remote telling us another getUpdates (or a webhook) owns this
  # bot's update stream. `PollerConflictError` exists for exactly that; leaving
  # it as a generic CommsError means the one condition the type was defined for
  # is the one condition that never raises it.
  def test_a_competing_poller_is_a_named_conflict_not_a_generic_error
    with_transport do |transport, server|
      server.script('getUpdates', status: 409, body: {
        'ok' => false, 'error_code' => 409,
        'description' => 'Conflict: terminated by other getUpdates request'
      }, times: 1)

      error = assert_raises(Comms::PollerConflictError) do
        transport.poll(next_offset: nil, limit: 50, timeout_s: 0)
      end
      assert_includes error.message, 'other getUpdates request',
                      "the API's own description names the competitor"
    end
  end

  def test_signal_answers_the_callback_query
    with_transport do |transport, server|
      server.script('answerCallbackQuery', body: { 'ok' => true, 'result' => true }, times: 1)

      assert_equal :acked, transport.signal(:ack, callback_query_id: 'q-1')
    end
  end

  def test_normalizer_marks_group_chats_and_membership
    with_transport do |_transport, _server|
      group = Tamoz::Telegram::Normalizer.new(surface_id: 's', surface_revision: 1)
                                         .normalize(update(1, chat_type: 'supergroup', text: 'hi')).wire

      assert_equal 'telegram:supergroup:22222222', group.fetch('conversation_id')

      member = { 'update_id' => 2,
                 'my_chat_member' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                       'from' => { 'id' => 111_111_11 } } }
      membership = Tamoz::Telegram::Normalizer.new(surface_id: 's', surface_revision: 1).normalize(member).wire

      assert_equal 'membership', membership.fetch('kind')
    end
  end

  # The callback envelope binds the originating message id (contract §7.1) so
  # the gateway can compare a press to the exact prompt message.
  def test_normalizer_binds_the_callback_message_id
    callback = { 'update_id' => 3,
                 'callback_query' => { 'id' => 'q-3', 'from' => { 'id' => 111_111_11 },
                                       'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                                      'message_id' => 2001 },
                                       'data' => 'deny:abc' } }
    wire = Tamoz::Telegram::Normalizer.new(surface_id: 's', surface_revision: 1).normalize(callback).wire

    assert_equal 'callback', wire.fetch('kind')
    assert_equal 2001, wire.fetch('callback_message_id')
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
