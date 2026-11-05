# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_transport_fixture'

class TamozTelegramTransportDeliveryTest < Minitest::Test
  include TelegramTransportFixture

  Comms = Tamoz::Comms

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

  def test_deliver_clarification_markup_stays_text_only
    calls = []
    client = Object.new
    client.define_singleton_method(:call) do |method, params|
      calls << [method, params]
      { 'message_id' => 42, 'date' => 1_752_700_800 }
    end
    transport = Tamoz::Telegram::Transport.new(client:, normalizer: nil)
    delivery = Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'control', text: 'Which file?',
      part_index: 0, part_count: 1, journaled: false, render_version: 1,
      content_digest: 'b' * 64,
      markup: JSON.generate('request_ref' => 'r1234567890', 'actions' => ['answer'])
    )

    assert_equal 42, transport.deliver(delivery).fetch('message_id')

    method, sent = calls.fetch(0)

    assert_equal 'sendMessage', method
    refute sent.key?('reply_markup'), 'clarification text must use reply or /answer ingress, not a callback'
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
        content_digest: 'c' * 64, operation: 'edit_message', reply_to: 42
      )

      assert_equal 42, transport.deliver(delivery).fetch('message_id')

      sent = JSON.parse(server.requests.last.fetch(:body))

      assert_equal 42, sent.fetch('message_id'),
                   'editMessageText must identify the message being edited'
      refute sent.key?('reply_to_message_id'),
             'reply_to_message_id is not a recognized editMessageText parameter'
    end
  end

  def test_a_send_timeout_is_ambiguous_never_retried
    with_transport(read_timeout: 0.05) do |transport, server|
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

  def test_an_oversized_send_response_is_ambiguous
    with_transport(max_response_bytes: 1024) do |transport, server|
      server.script('sendMessage', body: {
                      'ok' => true,
                      'result' => { 'message_id' => 17, 'date' => 1, 'text' => 'x' * 4096 }
                    }, times: 1)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'x',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'f' * 64
      )

      assert_raises(Comms::AmbiguousDeliveryError) { transport.deliver(delivery) }
    end
  end

  # A 409 on a send is not a poller conflict: PollerConflictError is a class the
  # delivery drainer cannot read, so classifying a send that way would kill the
  # drainer thread and strand the row. A send's outcome is ambiguous (F14-COR-01).
  def test_a_send_conflict_is_ambiguous_not_a_poller_conflict
    with_transport do |transport, server|
      server.script('sendMessage', status: 409, body: {
                      'ok' => false, 'error_code' => 409, 'description' => 'Conflict'
                    }, times: 1)
      delivery = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'hello',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'b' * 64
      )

      error = assert_raises(Comms::AmbiguousDeliveryError) { transport.deliver(delivery) }
      refute_kind_of Comms::PollerConflictError, error
    end
  end

  def test_signal_answers_the_callback_query
    with_transport do |transport, server|
      server.script('answerCallbackQuery', body: { 'ok' => true, 'result' => true }, times: 1)

      assert_equal :acked, transport.signal(:ack, callback_query_id: 'q-1')
    end
  end

  def test_deliver_sends_markdown_as_telegram_html
    calls = []
    client = Object.new
    client.define_singleton_method(:call) do |method, params|
      calls << [method, params]
      { 'message_id' => 42, 'date' => 1_752_700_800 }
    end
    transport = Tamoz::Telegram::Transport.new(client:, normalizer: nil)
    delivery = Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'Use **`a<b`**',
      part_index: 0, part_count: 1, journaled: true, render_version: 1, content_digest: 'b' * 64
    )

    transport.deliver(delivery)

    assert_equal({ 'chat_id' => '22222222', 'text' => 'Use <b><code>a&lt;b</code></b>', 'parse_mode' => 'HTML' },
                 calls.fetch(0).last)
  end

  def test_a_settled_prompt_toasts_and_clears_its_buttons
    with_transport do |transport, server|
      server.script('answerCallbackQuery', body: { 'ok' => true, 'result' => true }, times: 1)
      server.script('editMessageReplyMarkup', body: { 'ok' => true, 'result' => true }, times: 1)

      transport.signal(:ack, callback_query_id: 'q-1', text: 'Approved')

      assert_equal :cleared, transport.signal(:clear_buttons, conversation_id: 'telegram:chat:22222222', message_id: 7)

      bodies = server.requests.to_h { |request| [request[:method], JSON.parse(request[:body])] }

      assert_equal({ 'callback_query_id' => 'q-1', 'text' => 'Approved' }, bodies.fetch('answerCallbackQuery'))
      assert_equal({ 'chat_id' => '22222222', 'message_id' => 7, 'reply_markup' => { 'inline_keyboard' => [] } },
                   bodies.fetch('editMessageReplyMarkup'))
    end
  end

  def test_typing_signal_sends_the_chat_action_to_the_conversation
    with_transport do |transport, server|
      server.script('sendChatAction', body: { 'ok' => true, 'result' => true }, times: 1)

      assert_equal :typing, transport.signal(:typing, conversation_id: 'telegram:chat:22222222')
      sent = server.requests.find { |request| request[:method] == 'sendChatAction' }

      assert_equal({ 'chat_id' => '22222222', 'action' => 'typing' }, JSON.parse(sent[:body]))
    end
  end
end
