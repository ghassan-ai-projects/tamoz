# frozen_string_literal: true

require_relative 'test_helper'

# Pairing first contact (design §7): a brand-new sender on a pairing-mode
# surface is never left in silence. The gateway ensures one live hashed
# challenge per (surface, correspondent, conversation) and names its code in
# one bounded line while the durable record stays an ignored
# :pairing_pending observation. `/start <code>` is feedback only — binding
# activation remains exclusively the operator's approve_pairing.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
class CommsPairingFirstContactTest < Minitest::Test
  Comms = Tamoz::Comms

  SURFACE_ID = 'telegram-relay'
  BOT_ID = 7_463_512_991
  CONVERSATION_ID = 'telegram:chat:33333333'
  CORRESPONDENT_ID = 'telegram:user:44444444'
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  CODE_PATTERN = /\AThis chat isn't paired yet\. Read this code to your operator for approval: ([A-Z0-9]{8})\z/
  USAGE_REPLY = 'Usage: /start <pairing code>'
  WAITING_REPLY = 'That code matches a pending pairing request. Waiting for operator approval.'
  NO_MATCH_REPLY = "That code doesn't match a pending pairing request."
  PAIRED_REPLY = 'This chat is already paired.'

  def test_first_unbound_message_issues_one_hashed_challenge_and_names_the_code
    with_gateway do |gateway, transport, store|
      transport.batch([update(1, text: 'hello anyone there?')])

      assert_equal :served, gateway.serve_once(now: NOW, drain: false)

      assert_equal [%w[ignored pairing_pending]], inbound_dispositions(store, 1),
                   'the durable record stays an ignored observation'
      pending = store.pairing_challenges(status: 'pending')

      assert_equal 1, pending.length, 'exactly one challenge row exists'
      code = code_of(last_reply)

      assert_match CODE_PATTERN, last_reply
      row = pending.first

      refute_equal code, row.fetch('challenge_digest'), 'the store holds only the digest'
      assert_equal expected_digest(code), row.fetch('challenge_digest'),
                   'the stored digest is PairingChallenge\'s derivation over the plaintext'
      assert_operator row.fetch('expires_at_ms'), :>, ms(NOW), 'the challenge is issued live'
      assert_nil store.binding(correspondent_id: CORRESPONDENT_ID, surface_id: SURFACE_ID),
                 'a first contact binds nothing'
    end
  end

  def test_a_second_unbound_message_reuses_the_row_and_repeats_the_code
    with_gateway do |gateway, transport, store|
      first_code = contact(gateway, transport, 1, now: NOW)

      second_code = contact(gateway, transport, 2, text: 'any update?', now: NOW + 5)

      assert_equal first_code, second_code, 'the same code is repeated while the challenge lives'
      assert_equal 1, store.pairing_challenges(status: 'pending').length,
                   'the same row is reused, not duplicated'
    end
  end

  def test_start_with_the_matching_code_reports_waiting_without_touching_bindings
    with_gateway do |gateway, transport, store|
      code = contact(gateway, transport, 1, now: NOW)
      bindings_before = binding_row_count(store)

      assert_equal WAITING_REPLY, drive_command(gateway, transport, "/start #{code}", id: 2)

      assert_equal bindings_before, binding_row_count(store), '/start never mutates bindings'
      assert_nil store.binding(correspondent_id: CORRESPONDENT_ID, surface_id: SURFACE_ID)
      assert_empty checkpoints_turns(gateway), '/start admits no work'
    end
  end

  def test_start_refuses_bare_wrong_consumed_and_expired_codes
    with_gateway do |gateway, transport, store|
      code = contact(gateway, transport, 1, now: NOW)

      assert_equal USAGE_REPLY, drive_command(gateway, transport, '/start', id: 2),
                   'a bare /start gets the usage refusal shape'
      assert_equal NO_MATCH_REPLY, drive_command(gateway, transport, '/start ZZZZ9999', id: 3),
                   'an unknown code refuses bounded'

      seed_consumed_challenge(store, code: 'CONSUMED')
      assert_equal NO_MATCH_REPLY, drive_command(gateway, transport, '/start CONSUMED', id: 4),
                   'a consumed code no longer matches'

      expired = store.pairing_challenges(status: 'pending').first
      transport.batch([update(5, text: "/start #{code}")])
      later = NOW + Comms::Gateway::PAIRING_CODE_TTL_S + 60

      assert_equal :served, gateway.serve_once(now: later, drain: false)
      assert_equal NO_MATCH_REPLY, last_reply,
                   'an expired code refuses even though its digest still verifies'
      assert_operator expired.fetch('expires_at_ms'), :<=, ms(later)
    end
  end

  def test_an_expired_contact_gets_a_fresh_challenge_not_a_repeat
    with_gateway do |gateway, transport, store|
      first_code = contact(gateway, transport, 1, now: NOW)

      second_code = contact(gateway, transport, 2, now: NOW + Comms::Gateway::PAIRING_CODE_TTL_S + 60)

      refute_equal first_code, second_code, 'an expired challenge is replaced, not reused'
      rows = store.pairing_challenges(status: 'pending')

      assert_equal 2, rows.length, 'the expired row stays for the operator audit trail'
      assert_match CODE_PATTERN, last_reply
    end
  end

  def test_operator_approval_admits_the_next_message_through_the_real_gateway
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      code = contact(gateway, transport, 1, now: NOW)
      digest = store.pairing_challenges(status: 'pending').first.fetch('challenge_digest')

      outcome = store.approve_pairing(
        challenge_digest: digest, binding_wire: operator_binding_wire, now: NOW + 10
      )

      assert_equal :approved, outcome
      assert_equal 'active',
                   store.binding(correspondent_id: CORRESPONDENT_ID, surface_id: SURFACE_ID).fetch('status')

      transport.batch([update(2, text: 'now we are paired, make it blue')])
      assert_equal :served, gateway.serve_once(now: NOW + 20, drain: false)

      thread = Comms::Admission.thread_id(SURFACE_ID, CONVERSATION_ID)
      assert_equal 1, checkpoints.request_history(thread_id: thread).length,
                   'the next message enqueues a real turn'
      assert_match(/\AAccepted r[0-9a-f]{10}\./, last_reply)
      assert_empty store.pairing_challenges(status: 'pending'),
                   'approval consumed the challenge; nothing pends afterwards'
    end
  end

  def test_after_pairing_start_reports_already_paired_without_new_challenges
    with_gateway do |gateway, transport, store|
      contact(gateway, transport, 1, now: NOW)
      digest = store.pairing_challenges(status: 'pending').first.fetch('challenge_digest')
      assert_equal :approved,
                   store.approve_pairing(challenge_digest: digest, binding_wire: operator_binding_wire,
                                         now: NOW + 10)

      assert_equal PAIRED_REPLY, drive_command(gateway, transport, '/start WHATEVER1', id: 2)
      assert_equal USAGE_REPLY, drive_command(gateway, transport, '/start', id: 3)
    end
  end

  private

  # ===== harness =====

  def with_gateway
    Dir.mktmpdir('tamoz-pairing') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        appended = []
        adapter.singleton_class.define_method(:bind_comms_store) do |*bound|
          super(*bound).tap do |store|
            store.singleton_class.define_method(:append_delivery) do |delivery_wire, **arguments|
              appended << delivery_wire
              super(delivery_wire, **arguments)
            end
          end
        end
        definition = Tamoz.graph(name: 'pairing', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'pairing.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now: NOW)
        transport = ScriptedTransport.new
        gateway = Comms::Gateway.new(
          adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'pairing:test'
        )
        @appended = appended
        yield gateway, transport, store, adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  def descriptor
    @descriptor ||= Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID, bot_username: 'relay_bot' },
      admission: { direct: 'pairing' },
      threading: 'conversation', profile_id: 'relay',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def operator_binding_wire
    Comms::Binding.new(
      surface_id: SURFACE_ID, surface_revision: 1,
      correspondent_id: CORRESPONDENT_ID, conversation_id: CONVERSATION_ID,
      bound_at: NOW + 10, bound_by: 'operator:test'
    ).wire
  end

  def update(id, text: 'hello')
    { 'update_id' => id,
      'message' => { 'message_id' => id + 20_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 33_333_333, 'type' => 'private' },
                     'from' => { 'id' => 44_444_444 }, 'text' => text } }
  end

  class ScriptedTransport
    def batch(updates) = (@updates = updates)

    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      { updates: @updates.map { |update| normalize(update) }, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(delivery)
      (@sent ||= []) << delivery
      { 'message_id' => 1, 'date' => 1 }
    end

    def deliveries = @sent || []

    def normalize(update)
      Comms::InboundEnvelope.new(
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

  # ===== helpers =====

  # One unbound contact through the real loop; returns the code it named.
  def contact(gateway, transport, id, text: 'hello there', now:)
    transport.batch([update(id, text:)])
    outcome = gateway.serve_once(now:, drain: false)

    raise "contact #{id} returned #{outcome.inspect}" unless outcome == :served

    code_of(last_reply).tap { |code| raise "no code in #{last_reply.inspect}" unless code }
  end

  def drive_command(gateway, transport, text, id:)
    transport.batch([update(id, text:)])
    outcome = gateway.serve_once(now: NOW + (id % 7) + 1, drain: false)

    raise "command #{id} returned #{outcome.inspect}" unless outcome == :served

    last_reply
  end

  def seed_consumed_challenge(store, code:)
    digest = expected_digest(code)
    store.__send__(:transaction, 'test.pairing.seed') do |txn|
      txn.execute('test.pairing.seed', <<~SQL, [digest, SURFACE_ID, CORRESPONDENT_ID, CONVERSATION_ID])
        INSERT INTO tamoz_comms_pairing_challenges (
          challenge_digest, surface_id, correspondent_id, conversation_id,
          status, attempts, expires_at_ms, created_at_ms
        ) VALUES (?, ?, ?, ?, 'consumed', 0, 0, 0)
      SQL
    end
  end

  def expected_digest(code)
    Comms::Canonical.hexdigest(
      Comms::PairingChallenge::DIGEST_DOMAIN,
      [SURFACE_ID, CORRESPONDENT_ID, CONVERSATION_ID, code]
    )
  end

  def binding_row_count(store)
    store.__send__(:read, 'test.pairing.bindings') do |txn|
      txn.scalar('test.pairing.bindings', 'SELECT COUNT(*) FROM tamoz_comms_bindings').to_i
    end
  end

  def checkpoints_turns(gateway)
    store = gateway.instance_variable_get(:@store)
    generation = begin
      store.conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)
    rescue KeyError
      0
    end
    thread = Comms::Admission.thread_id(SURFACE_ID, CONVERSATION_ID, generation:)
    gateway.instance_variable_get(:@checkpoints).request_history(thread_id: thread)
  end

  def inbound_dispositions(store, update_id)
    store.__send__(:read, 'test.pairing.inbound.read') do |txn|
      txn.rows('test.pairing.inbound.read',
               'SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?', [update_id])
    end
  end

  def code_of(reply)
    match = CODE_PATTERN.match(reply.to_s)
    match && match[1]
  end

  def last_reply = @appended.last.fetch('text')

  def ms(now)
    (now.utc.to_r * 1000).to_i
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
