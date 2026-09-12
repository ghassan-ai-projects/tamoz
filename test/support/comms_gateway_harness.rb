# frozen_string_literal: true

# Shared channel-gateway harness for the suites that drive real serve_once
# passes against a real SQLite runtime database: one surface descriptor, one
# update factory, one scripted transport, and one throwaway graph definition.
# The parity, exposure, and cancellation-visibility suites assert different
# contracts over the same wire shapes, so the shapes live here exactly once.
module CommsGatewayHarness
  SURFACE_ID = 'telegram-ops'
  BOT_ID = 7_463_512_990
  CONVERSATION_ID = 'telegram:chat:22222222'
  CORRESPONDENT_ID = 'telegram:user:11111111'
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)

  module_function

  def descriptor
    Tamoz::Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: [CORRESPONDENT_ID] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 200, per_chat_messages_per_s: 30.0,
                global_messages_per_s: 100.0 }
    )
  end

  def update(id, text: 'first turn')
    { 'update_id' => id,
      'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 22_222_222, 'type' => 'private' },
                     'from' => { 'id' => 111_111_11 }, 'text' => text } }
  end

  def graph_definition(name)
    Tamoz.graph(name: name, version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: "#{name}.finish", version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  # The scripted channel transport: batched inbound updates, no real network.
  class ScriptedTransport
    def batch(updates) = (@updates = updates)

    def poll(**)
      ids = @updates.map { |update| update.fetch('update_id') }
      { updates: @updates.map { |update| normalize(update) }, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(_delivery)
      { 'message_id' => 1, 'date' => 1 }
    end

    def normalize(update)
      Tamoz::Comms::InboundEnvelope.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        update_id: update.fetch('update_id'),
        raw_payload_hash: Digest::SHA256.hexdigest(JSON.generate(update)),
        parser_version: 1,
        kind: update.dig('message', 'text').start_with?('/') ? 'command' : 'text',
        correspondent_id: CORRESPONDENT_ID,
        conversation_id: CONVERSATION_ID,
        message_id: update.dig('message', 'message_id'),
        text: update.dig('message', 'text'),
        observed_time: Time.at(update.dig('message', 'date')).utc
      ).wire
    end
  end
end
