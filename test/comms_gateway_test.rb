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

  def with_gateway(limits: {})
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
        appended = []
        # The gateway binds its own store, so the capture rides the adapter:
        # every appended delivery wire is recorded for reply-targeting proofs.
        adapter.singleton_class.define_method(:bind_comms_store) do |*bound|
          super(*bound).tap do |store|
            store.singleton_class.define_method(:append_delivery) do |delivery_wire, **arguments|
              appended << delivery_wire
              super(delivery_wire, **arguments)
            end
          end
        end
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor(limits:).wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
        transport = ScriptedTransport.new
        gateway = Tamoz::Comms::Gateway.new(
          adapter:, checkpoints:, transport:, descriptor: descriptor(limits:),
          poller_owner: 'gateway:test'
        )
        yield gateway, transport, store, adapter, checkpoints, appended
      ensure
        adapter&.close
      end
    end
  end

  def descriptor(limits: {})
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
                global_messages_per_s: 25.0 }.merge(limits)
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
      'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                     'from' => { 'id' => user_id }, 'text' => text } }
  end

  def callback_update(id, data:, callback_message_id:, user_id: 111_111_11)
    { 'update_id' => id,
      'callback_query' => { 'id' => "cb#{id}", 'data' => data,
                            'from' => { 'id' => user_id },
                            'message' => { 'message_id' => callback_message_id, 'date' => 1_752_700_800,
                                           'chat' => { 'id' => 222_222_22, 'type' => 'private' } } } }
  end

  def seed_binding(store, now: Time.utc(2026, 8, 10, 12, 0, 0))
    store.bind_correspondent(binding_wire, now:)
  end

  def inbound_dispositions(store, update_id)
    store.__send__(:read, 'test.gateway.inbound.read') do |txn|
      txn.rows('test.gateway.inbound.read', <<~SQL, [update_id])
        SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?
      SQL
    end
  end

  def stored_hashes(store, update_id)
    store.__send__(:read, 'test.gateway.hash.read') do |txn|
      txn.rows('test.gateway.hash.read', 'SELECT raw_payload_hash FROM tamoz_comms_inbound WHERE update_id = ?',
               [update_id]).map(&:first)
    end
  end

  def membership_update(id, chat_id:)
    { 'update_id' => id,
      'my_chat_member' => { 'chat' => { 'id' => chat_id, 'type' => 'private' },
                            'from' => { 'id' => 111_111_11 } } }
  end

  def request_row_count(store)
    store.__send__(:read, 'test.gateway.request.count') do |txn|
      txn.scalar('test.gateway.request.count', 'SELECT COUNT(*) FROM tamoz_comms_requests').to_i
    end
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

  # A follow-up message is planned with the thread's transcript: the gateway
  # reads the conversation history and it rides the second turn's payload
  # (the first contact stays bare — there is nothing to recall yet). And the
  # synchronous reply says what will actually happen: while the first
  # request is still open the follow-up QUEUES behind it — "Accepted" alone
  # would read as "starting now".
  def test_a_follow_up_message_queues_and_carries_the_transcript
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      start = Time.utc(2026, 8, 10, 12, 0, 0)
      transport.batch([update(101, text: 'make it blue')])

      assert_equal :served, gateway.serve_once(now: start)

      transport.batch([update(102, text: 'and the font?')])

      assert_equal :served, gateway.serve_once(now: start + 2)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      requests = checkpoints.request_history(thread_id: thread)

      assert_equal 2, requests.length
      assert_equal 'make it blue', requests.first.payload.fetch('task')
      task = requests.last.payload.fetch('task')
      assert_equal 'and the font?', task.fetch('text')
      context = task.fetch('context')
      assert_equal thread, context.fetch('thread_id')
      assert_equal requests.last.request_id, context.fetch('request_id')
      assert_equal [{ 'role' => 'user', 'text' => 'make it blue' }], context.fetch('fragments')
      assert_equal Tamoz::Agent::SessionPlanningContext.turn_payload(
        thread_id: thread,
        request_id: requests.last.request_id,
        text: 'and the font?',
        fragments: [{ 'role' => 'user', 'text' => 'make it blue' }]
      ), { 'task' => task }
      replies = transport.deliveries.map(&:text)
      first_ref = Comms::Lifecycle::RequestRef.for(
        Tamoz::Core::RequestIdentity.request_id(
          surface_id: 'telegram-ops', surface_revision: 1, bot_id: 7_463_512_990,
          update_id: 101, raw_payload_hash: transport.digest_of(update(101, text: 'make it blue'))
        )
      )

      assert_equal "Accepted #{first_ref}. I will report committed progress.", replies.first
      assert_match(/Accepted r\h{10}; queued behind earlier work/, replies.last)
    end
  end

  def test_a_replayed_update_does_not_create_a_second_accepted_delivery
    with_gateway do |gateway, transport, store, adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(101, text: 'first'), update(102, text: 'second')])

      assert_equal :served, gateway.serve_once(drain: false)

      # The replay sees a different queue state, so its old implementation
      # rendered a second, different accepted/queued control for update 101.
      transport.batch([update(101, text: 'first')])
      restarted_gateway = Tamoz::Comms::Gateway.new(
        adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:restarted'
      )
      assert_equal :served, restarted_gateway.serve_once(drain: false)

      accepted = store.outbox_rows(
        surface_id: 'telegram-ops', statuses: %w[pending]
      ).select { |row| row.fetch('kind') == 'accepted' }
      assert_equal 2, accepted.length, 'one accepted control per admitted update'
    end
  end

  # A long poll that times out is the normal weather of long polling, not the
  # end of the gateway: nothing was observed, the durable offset is untouched,
  # and the very next pass still admits the message that was waiting.
  def test_a_transient_poll_failure_does_not_end_the_gateway
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(101, text: 'hello')])
      transport.transient_polls = 2

      assert_equal :transient, gateway.serve_once
      assert_equal :transient, gateway.serve_once
      assert_nil store.poll_offset(bot_id: 7_463_512_990),
                 'a read that observed nothing must not move the durable offset'

      assert_equal :served, gateway.serve_once
      assert_equal 102, store.poll_offset(bot_id: 7_463_512_990)
      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      refute_nil store.request_conversation(thread_id: thread),
                 'the message waiting through the blip must still become a turn'
    end
  end

  def test_the_long_running_loop_retries_a_generic_transport_error
    with_gateway do |gateway, transport, _store|
      transport.comms_errors = 1
      runner = Thread.new do
        gateway.serve_loop(interval_s: 0, sleeper: ->(_seconds) {})
      end

      Timeout.timeout(5) { sleep 0.01 until transport.poll_calls >= 2 }
      gateway.stop

      assert_equal :stopped, runner.value
      assert_operator transport.poll_calls, :>=, 2
    end
  end

  def test_the_polling_lease_is_renewed_after_a_long_poll
    with_gateway do |gateway, _transport, store|
      assert_equal :started, gateway.start(now: Time.utc(2026, 8, 11, 12, 0, 0))
      later = Time.utc(2026, 8, 11, 12, 1, 10)

      assert_equal :served, gateway.serve_once(now: later)
      state = store.poll_state(bot_id: 7_463_512_990)

      assert_operator state.fetch('poller_expires_at_ms'), :>, later.to_f * 1000
    ensure
      gateway&.stop
    end
  end

  # `stop` must END the loop, not merely drop the lease. A gateway that
  # released its lease and kept polling would be reading an update stream it
  # no longer owns — the exact condition Telegram answers with a 409.
  def test_stop_ends_the_serve_loop_and_releases_the_lease
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([])

      runner = Thread.new { gateway.serve_loop(interval_s: 0.01) }
      Timeout.timeout(5) { sleep 0.05 until store.poll_state(bot_id: 7_463_512_990)&.fetch('poller_owner_id') }

      gateway.stop
      outcome = Timeout.timeout(5) { runner.value }

      assert_equal :stopped, outcome, 'the serve loop must end when asked'
      assert_nil store.poll_state(bot_id: 7_463_512_990).fetch('poller_owner_id'),
                 'a stopped gateway must not keep the poller lease'
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

  def test_known_commands_are_controls_and_never_become_task_text
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(1, text: '/help'), update(2, text: '/status')])

      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_empty checkpoints.request_history(thread_id: thread)
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal(%w[control control], rows.map { |row| row.fetch('kind') })
      refute(rows.any? { |row| %w[/help /status].include?(row.fetch('text')) }) # rubocop:disable Performance/CollectionLiteralInLoop
    end
  end

  def test_cancel_is_a_typed_redirect_and_not_a_model_task
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(1, text: 'work'), update(2, text: '/cancel')])

      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      history = checkpoints.request_history(thread_id: thread)

      assert_equal %i[turn redirect], history.map(&:operation)
      assert history.last.payload.fetch('task').fetch('cancel')
      refute_match(%r{/cancel}, history.last.payload.inspect)

      turn_request_id = history.first.request_id
      row = store.__send__(:read, 'test.gateway.cancel.stamp') do |txn|
        txn.first('test.gateway.cancel.stamp', <<~SQL, [turn_request_id])
          SELECT cancellation_requested_at_ms FROM tamoz_comms_requests WHERE request_id = ?
        SQL
      end

      refute_nil row&.first, '/cancel handling must stamp the requested point in the same commit'
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

      second = Tamoz::Comms::Gateway.new(
        adapter:, checkpoints: build_checkpoints(adapter),
        transport:, descriptor:, poller_owner: 'gateway:other'
      )

      assert_equal :poller_busy, second.start,
                   'a live fenced poller lease is not claimable by a second gateway'
    ensure
      gateway&.stop
    end
  end

  # Invariant 1 / hard-zero list: the same (surface, bot, update_id) under
  # different payload bytes is a durable quarantine with one bounded reply —
  # never a silent duplicate, never a second turn. The conflict lands on the
  # ONE anchor row (counter + last conflicting digest), so the identity reads
  # as quarantined, not as two rows.
  def test_an_integrity_conflict_quarantines_with_a_bounded_reply_and_no_turn
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(300, text: 'original bytes')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(300, text: 'conflicting bytes')])
      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_equal [%w[quarantined integrity_conflict]], inbound_dispositions(store, 300)
      assert_equal 1, request_row_count(store), 'the conflict enqueues no second request'
      assert_equal 1, checkpoints.request_history(thread_id: thread).length,
                   'the conflicting update never becomes a turn'
      replies = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                     .select { |row| row.fetch('kind') == 'control' }

      assert_equal 1, replies.length
      assert_equal 'This update conflicts with an earlier message carrying the same identity. ' \
                   'An operator can review it.', replies.first.fetch('text')
    end
  end

  # The digest admission dedups on is the PRODUCTION normalizer's digest of
  # the raw Bot-API update — proven end to end: the stored raw_payload_hash
  # equals Normalizer.normalize(update)'s own, and mutating any meaningful
  # field under the same update_id (text here, chat id for membership) is a
  # detectable integrity conflict.
  def test_admission_binds_the_real_normalizer_digest_and_detects_mutations_end_to_end
    with_gateway do |_gateway, _transport, store|
      seed_binding(store)
      normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)
      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      admit = lambda do |wire|
        store.admit_and_enqueue(
          wire, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                thread:, profile_id: 'ops', reservation: 9, now: Time.utc(2026, 8, 10, 12, 0, 0)
        )
      end

      original = normalizer.normalize(update(600, text: 'original bytes')).wire

      assert_equal :enqueued, admit.call(original)
      assert_equal [original.fetch('raw_payload_hash')], stored_hashes(store, 600),
                   'the stored digest is the production normalizer\'s'

      mutated = normalizer.normalize(update(600, text: 'conflicting bytes')).wire

      refute_equal original.fetch('raw_payload_hash'), mutated.fetch('raw_payload_hash')

      assert_equal :integrity_conflict, admit.call(mutated)

      membership_first = normalizer.normalize(membership_update(601, chat_id: 111_111)).wire
      membership_second = normalizer.normalize(membership_update(601, chat_id: 222_222)).wire

      refute_equal membership_first.fetch('raw_payload_hash'),
                   membership_second.fetch('raw_payload_hash'),
                   'membership digests are sensitive to the chat id under one update_id'
    end
  end

  def test_the_open_request_limit_rejects_with_a_bounded_reply_and_no_turn
    with_gateway(limits: { max_open_requests: 1 }) do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(310, text: 'first turn')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(311, text: 'second turn')])
      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_equal [%w[rejected open_request_limit]], inbound_dispositions(store, 311)
      assert_equal 1, request_row_count(store), 'the refused update enqueues no work'
      assert_equal 1, checkpoints.request_history(thread_id: thread).length
      replies = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                     .select { |row| row.fetch('kind') == 'control' }

      assert_equal 1, replies.length
      assert_equal 'This channel has too much open work right now; try again later.',
                   replies.first.fetch('text')
    end
  end

  def test_an_oversized_inbound_message_rejects_with_a_bounded_reply_and_no_turn
    with_gateway(limits: { max_inbound_bytes: 32 }) do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(320, text: 'x' * 33)])

      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_equal [%w[rejected inbound_too_large]], inbound_dispositions(store, 320)
      assert_equal 0, request_row_count(store), 'the oversized update enqueues no work'
      assert_empty checkpoints.request_history(thread_id: thread)
      replies = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                     .select { |row| row.fetch('kind') == 'control' }

      assert_equal 1, replies.length
      assert_equal "That message exceeds this channel's size limit.", replies.first.fetch('text')
    end
  end

  # Invariant 2: a control reply targets the message id the update carries,
  # never the update_id the fixtures once kept equal to it.
  def test_control_replies_target_the_message_id_not_the_update_id
    with_gateway do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(400, text: '/help')])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last

      assert_equal 'control', reply.fetch('kind')
      assert_equal 10_400, reply.fetch('reply_to'), 'the reply targets the carried message id'
      refute_equal 400, reply.fetch('reply_to')
    end
  end

  def test_a_callback_reply_targets_the_callback_message_id_not_the_update_id
    with_gateway do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      store.revoke_binding(correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops',
                           reason: 'revoked for test', now: Time.utc(2026, 8, 10, 12, 0, 0))
      transport.batch([callback_update(500, data: 'deny:r1', callback_message_id: 88)])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last

      assert_equal 'control', reply.fetch('kind')
      assert_equal 88, reply.fetch('reply_to'), 'the reply targets the callback message id'
      refute_equal 500, reply.fetch('reply_to')
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
    attr_accessor :receipt, :raise_ambiguous, :transient_polls, :comms_errors

    def initialize
      @updates = []
      @transient_polls = 0
      @comms_errors = 0
      @poll_calls = 0
    end

    def batch(updates)
      @updates = updates
    end

    # rubocop:disable Lint/UnusedMethodArgument -- the seam signature.
    def poll(next_offset:, limit:, timeout_s:)
      @poll_calls += 1
      if @comms_errors.positive?
        @comms_errors -= 1
        raise Comms::CommsError, 'temporary Telegram API failure'
      end
      if @transient_polls.positive?
        @transient_polls -= 1
        raise Comms::TransientTransportError, 'long poll timed out'
      end

      ids = @updates.map { |update| update.fetch('update_id') }
      {
        updates: @updates.map { |update| normalize(update) },
        next_offset: ids.max && (ids.max + 1)
      }
    end

    attr_reader :poll_calls
    # rubocop:enable Lint/UnusedMethodArgument

    def deliver(delivery)
      raise Comms::AmbiguousDeliveryError, 'timeout' if @raise_ambiguous

      @sent ||= []
      @sent << delivery
      @receipt || { 'message_id' => 1, 'date' => 1 }
    end

    def deliveries = @sent || []

    def normalize(update)
      if (callback = update['callback_query'])
        Comms::InboundEnvelope.new(
          surface_id: 'telegram-ops', surface_revision: 1,
          update_id: update.fetch('update_id'), raw_payload_hash: payload_digest(update),
          parser_version: 1, kind: 'callback',
          correspondent_id: "telegram:user:#{callback.dig('from', 'id')}",
          conversation_id: "telegram:chat:#{callback.dig('message', 'chat', 'id')}",
          callback_message_id: callback.dig('message', 'message_id'),
          text: callback['data'],
          observed_time: Time.at(callback.dig('message', 'date') || 1_752_700_800).utc
        ).wire
      else
        Comms::InboundEnvelope.new(
          surface_id: 'telegram-ops', surface_revision: 1,
          update_id: update.fetch('update_id'), raw_payload_hash: payload_digest(update),
          parser_version: 1, kind: update.dig('message', 'text')&.start_with?('/') ? 'command' : 'text',
          correspondent_id: "telegram:user:#{update.dig('message', 'from', 'id')}",
          conversation_id: "telegram:chat:#{update.dig('message', 'chat', 'id')}",
          message_id: update.dig('message', 'message_id'),
          text: update.dig('message', 'text'),
          observed_time: Time.at(update.dig('message', 'date')).utc
        ).wire
      end
    end

    def payload_digest(update)
      Digest::SHA256.hexdigest(JSON.generate(update))
    end

    def digest_of(update) = payload_digest(update)
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
