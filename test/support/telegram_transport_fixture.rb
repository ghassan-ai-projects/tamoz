# frozen_string_literal: true

require_relative '../test_helper'
require_relative 'telegram_fixture_server'

module TelegramTransportFixture
  def with_transport(max_response_bytes: Tamoz::Telegram::Client::DEFAULT_MAX_RESPONSE_BYTES, read_timeout: 1.0)
    server = TelegramFixtureServer.new
    client = Tamoz::Telegram::Client.new('test-token', origin: server.url, read_timeout:,
                                                       max_response_bytes:)
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
        'message_id' => id + 10_000,
        'date' => 1_752_700_800,
        'chat' => { 'id' => chat_id, 'type' => chat_type },
        'from' => { 'id' => user_id },
        'text' => text
      }
    }.compact
  end
end
