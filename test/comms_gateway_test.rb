# frozen_string_literal: true

require_relative 'test_helper'

# Slice G (COMMS_TELEGRAM_PLAN §3) — the gateway loop (design §5/§10,
# ADR-042): one fenced poller per bot, inbound updates resolve to durable
# dispositions, the offset is persisted only after the whole prefix is
# durable, and the outbox drains with honest ambiguity. The transport is
# scripted in-memory so the loop is deterministic.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
class CommsGatewayTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_gateway
    Dir.mktmpdir('tamoz-gateway') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'gateway', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'gateway.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
        transport = ScriptedTransport.new
        gateway = Tamoz::Agent::CommsGateway.new(
          adapter:, checkpoints:, transport:, descriptor:,
          poller_owner: 'gateway:test'
        )
        yield gateway, transport, store, adapter
      ensure
        adapter&.close
      end
    end
  end

  def descriptor
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def binding_wire
    Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      bound_at: Time.utc(2026, 8, 10, 12, 0, 0), bound_by: 'operator:ghassan'
    ).wire
  end

  def update(id, text: 'hello', user_id: 111_111_11)
    { 'update_id' => id,
      'message' => { 'message_id' => id, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                     'from' => { 'id' => user_id }, 'text' => text } }
  end

  def seed_binding(store, now: Time.utc(2026, 8, 10, 12, 0, 0))
    store.bind_correspondent(binding_wire, now:)
  end

  def test_an_inbound_message_becomes_a_queued_turn_and_the_offset_persists
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(101, text: 'hello')])

      assert_equal :served, gateway.serve_once

      assert_equal 102, store.poll_offset(bot_id: 7_463_512_990)
      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      route = store.request_conversation(thread_id: thread)

      refute_nil route, 'the first request must bind the conversation route'
      assert_equal 'telegram:chat:22222222', route.fetch('conversation_id')
    end
  end

  def test_an_unknown_command_gets_a_typed_control_reply
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(1, text: '/eval rm -rf /')])
      transport.receipt = { 'message_id' => 7, 'date' => 1 }

      assert_equal :served, gateway.serve_once

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded])

      assert_equal 1, rows.length
      assert_equal 'control', rows.first.fetch('kind')
      assert_equal 0, rows.first.fetch('journaled'),
                   'control replies are ephemeral and unjournaled'
    end
  end

  def test_an_unbound_sender_is_ignored
    with_gateway do |gateway, transport, _store|
      transport.batch([update(1, text: 'hello', user_id: 999_999_99)])

      assert_equal :served, gateway.serve_once
      assert_equal [], transport.deliveries
    end
  end

  def test_the_outbox_drains_with_a_receipt
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([])
      transport.receipt = { 'message_id' => 42, 'date' => 1_752_700_800 }
      store.append_delivery(
        Comms::Delivery.build(
          conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'answer',
          part_index: 0, part_count: 1, journaled: true, render_version: 1,
          content_digest: 'b' * 64
        ).wire,
        surface_id: 'telegram-ops', capacity: 10, now: Time.utc(2026, 8, 10, 12, 0, 0)
      )

      assert_equal :served, gateway.serve_once

      assert_equal 1, transport.deliveries.length
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[succeeded])

      assert_equal 1, rows.length
      refute_nil rows.first.fetch('receipt')
    end
  end

  def test_an_ambiguous_send_is_unknown_never_retried
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([])
      transport.raise_ambiguous = true
      store.append_delivery(
        Comms::Delivery.build(
          conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'x',
          part_index: 0, part_count: 1, journaled: true, render_version: 1,
          content_digest: 'c' * 64
        ).wire,
        surface_id: 'telegram-ops', capacity: 10, now: Time.utc(2026, 8, 10, 12, 0, 0)
      )

      assert_equal :served, gateway.serve_once
      assert_equal 1, store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[unknown]).length
    end
  end

  def test_two_gateways_cannot_poll_the_same_bot
    with_gateway do |gateway, transport, _store, adapter|
      transport.batch([])

      assert_equal :started, gateway.start

      second = Tamoz::Agent::CommsGateway.new(
        adapter:, checkpoints: build_checkpoints(adapter),
        transport:, descriptor:, poller_owner: 'gateway:other'
      )

      assert_equal :poller_busy, second.start,
                   'a live fenced poller lease is not claimable by a second gateway'
    ensure
      gateway&.stop
    end
  end

  private

  def build_checkpoints(adapter)
    definition = Tamoz.graph(name: 'gateway-2', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 'gateway-2.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    definition.compile(checkpointer: adapter).checkpointer
  end

  # A scripted Transport for the loop: batches of raw updates, optional
  # receipt, optional ambiguity.
  class ScriptedTransport
    attr_accessor :receipt, :raise_ambiguous

    def initialize
      @updates = []
    end

    def batch(updates)
      @updates = updates
    end

    # rubocop:disable Lint/UnusedMethodArgument -- the seam signature.
    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      {
        updates: @updates.map { |update| normalize(update) },
        next_offset: ids.max && (ids.max + 1)
      }
    end
    # rubocop:enable Lint/UnusedMethodArgument

    def deliver(delivery)
      raise Comms::AmbiguousDeliveryError, 'timeout' if @raise_ambiguous

      @sent ||= []
      @sent << delivery
      @receipt || { 'message_id' => 1, 'date' => 1 }
    end

    def deliveries = @sent || []

    def normalize(update)
      Comms::InboundEnvelope.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        update_id: update.fetch('update_id'), raw_payload_hash: 'a' * 64,
        parser_version: 1, kind: update.dig('message', 'text')&.start_with?('/') ? 'command' : 'text',
        correspondent_id: "telegram:user:#{update.dig('message', 'from', 'id')}",
        conversation_id: "telegram:chat:#{update.dig('message', 'chat', 'id')}",
        text: update.dig('message', 'text'),
        observed_time: Time.at(update.dig('message', 'date')).utc
      ).wire
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
