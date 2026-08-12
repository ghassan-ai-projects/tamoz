# frozen_string_literal: true

require_relative 'test_helper'

# Slice H (COMMS_TELEGRAM_PLAN §3) — the deny-only callback path (design §9,
# ADR-043): a prompt activates only after its send receipt is durable, a
# button press resolves exactly one ACTIVE prompt to a deny decision, and a
# replay, expiry, or swapped binding never resolves (invariant 58).
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength, Lint/UnusedMethodArgument
class CommsDenyCallbackTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_engine
    Dir.mktmpdir('tamoz-deny') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'deny', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'deny.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        yield adapter, checkpoints
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

  def test_a_callback_resolves_one_active_prompt_to_a_deny_decision
    with_engine do |adapter, checkpoints|
      store = adapter.bind_comms_store(checkpoints)
      store.deploy_surface(descriptor.wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
      transport = ScriptedTransport.new
      gateway = Tamoz::Agent::CommsGateway.new(
        adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:test'
      )
      transport.batch([])

      reference, prompt = Comms::ApprovalPrompt.build(
        surface_id: 'telegram-ops', surface_revision: 1,
        thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
        interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
        correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
        prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
      )
      store.insert_prompt(prompt.wire)
      store.activate_prompt(reference_digest: prompt.reference_digest,
                            now: Time.utc(2026, 8, 10, 12, 0, 1), receipt: '2001')

      Comms::InboundEnvelope.new(
        surface_id: 'telegram-ops', surface_revision: 1, update_id: 55,
        raw_payload_hash: 'b' * 64, parser_version: 1, kind: 'callback',
        correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
        callback_message_id: 2001,
        text: reference, observed_time: Time.utc(2026, 8, 10, 12, 0, 2)
      ).wire
      transport.batch([{ 'update_id' => 55,
                         'callback_query' => { 'id' => 'q-1',
                                               'from' => { 'id' => 111_111_11 },
                                               'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                                              'message_id' => 2001 },
                                               'data' => reference } }])
      transport.receipt = { 'message_id' => 1, 'date' => 1 }

      assert_equal :served, gateway.serve_once(now: Time.utc(2026, 8, 10, 12, 0, 2))

      decision = adapter.bind_comms_decision_store
                        .pending_decision_for(
                          thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
                          interrupt_digest: prompt.interrupt_digest, now: Time.utc(2026, 8, 10, 12, 0, 3)
                        )

      refute_nil decision, 'the deny decision must be recorded for the worker'
      assert_equal 'deny', decision.fetch('direction')
      assert_equal 'telegram_user', decision.fetch('actor_kind')
      assert_equal 'telegram:user:11111111', decision.fetch('actor_id')
    end
  end

  def test_a_replayed_reference_is_consumed_exactly_once
    with_engine do |adapter, checkpoints|
      store = adapter.bind_comms_store(checkpoints)
      store.deploy_surface(descriptor.wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
      transport = ScriptedTransport.new
      gateway = Tamoz::Agent::CommsGateway.new(
        adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:test'
      )
      transport.batch([])

      reference = 'fixed-reference'
      digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
      store.insert_prompt(prompt_for(reference, digest).wire)
      store.activate_prompt(reference_digest: digest, now: Time.utc(2026, 8, 10, 12, 0, 1), receipt: '2001')

      transport.batch([callback_update(reference, 100)])
      gateway.serve_once(now: Time.utc(2026, 8, 10, 12, 0, 2))
      transport.batch([callback_update(reference, 101)])
      gateway.serve_once(now: Time.utc(2026, 8, 10, 12, 0, 3))

      decisions = adapter.bind_comms_decision_store.each_decision(thread_id: 'tg.ops.abc')

      assert_equal 1, decisions.length, 'the replayed reference is consumed exactly once'
    end
  end

  def test_an_expired_prompt_never_resolves
    with_engine do |adapter, checkpoints|
      store = adapter.bind_comms_store(checkpoints)
      store.deploy_surface(descriptor.wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
      transport = ScriptedTransport.new
      gateway = Tamoz::Agent::CommsGateway.new(
        adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:test'
      )
      transport.batch([])

      _reference, prompt = Comms::ApprovalPrompt.build(
        surface_id: 'telegram-ops', surface_revision: 1,
        thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
        interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
        correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
        prompt_ttl_s: 1, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
      )
      store.insert_prompt(prompt.wire)
      store.activate_prompt(reference_digest: prompt.reference_digest,
                            now: Time.utc(2026, 8, 10, 12, 0, 1), receipt: '2001')

      # A press after the TTL: the prompt is expired and must not resolve.
      transport.batch([callback_update('x', 200)])
      transport.receipt = { 'message_id' => 1, 'date' => 1 }
      gateway.serve_once(now: Time.utc(2026, 8, 10, 12, 0, 2))

      assert_empty adapter.bind_comms_decision_store.each_decision(thread_id: 'tg.ops.abc'),
                   'an expired prompt never yields a decision'
    end
  end

  private

  def prompt_for(_reference, digest)
    Comms::ApprovalPrompt.new(
      reference_digest: digest, surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupt_digest: 'c' * 64, correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      created_at: Time.utc(2026, 8, 10, 12, 0, 0),
      expires_at: Time.utc(2026, 8, 10, 12, 15, 0)
    )
  end

  def callback_envelope(reference)
    Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id: 1,
      raw_payload_hash: 'c' * 64, parser_version: 1, kind: 'callback',
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      text: reference, observed_time: Time.utc(2026, 8, 10, 12, 0, 0)
    ).wire
  end

  def callback_update(reference, id)
    { 'update_id' => id,
      'callback_query' => { 'id' => "q-#{id}", 'from' => { 'id' => 111_111_11 },
                            'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                           'message_id' => 2001 },
                            'data' => reference } }
  end

  class ScriptedTransport
    attr_accessor :receipt

    def batch(updates)
      @updates = updates
    end

    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      {
        updates: @updates.map { |update| normalize(update) },
        next_offset: ids.max && (ids.max + 1)
      }
    end

    def deliver(_delivery)
      @receipt || { 'message_id' => 1, 'date' => 1 }
    end

    def normalize(update)
      callback = update['callback_query']
      message = callback['message']
      Comms::InboundEnvelope.new(
        surface_id: 'telegram-ops', surface_revision: 1,
        update_id: update.fetch('update_id'), raw_payload_hash: 'd' * 64,
        parser_version: 1, kind: 'callback',
        correspondent_id: "telegram:user:#{callback.fetch('from').fetch('id')}",
        conversation_id: "telegram:chat:#{message.fetch('chat').fetch('id')}",
        callback_message_id: message.fetch('message_id'),
        text: callback.fetch('data'), observed_time: Time.utc(2026, 8, 10, 12, 0, 0)
      ).wire
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:enable Metrics/BlockLength, Lint/UnusedMethodArgument
