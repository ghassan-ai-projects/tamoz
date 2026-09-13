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

  def test_start_authenticates_the_transport_before_polling
    with_gateway do |gateway, transport, *|
      assert_equal :started, gateway.start
      assert_equal 1, transport.authentication_calls
    ensure
      gateway&.stop
    end
  end

  def test_start_rejects_a_transport_identity_mismatch
    with_gateway do |gateway, transport, *|
      transport.authenticated_id = 99

      assert_equal :auth_failed, gateway.start
      assert_equal 1, transport.authentication_calls
    ensure
      gateway&.stop
    end
  end

  def with_gateway(limits: {}, controls: nil)
    Dir.mktmpdir('tamoz-gateway') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        checkpoints = gateway_graph('gateway').compile(checkpointer: adapter).checkpointer
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
          poller_owner: 'gateway:test', controls:
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

  def request_ref(update, transport)
    Comms::Lifecycle::RequestRef.for(
      Tamoz::Core::RequestIdentity.request_id(
        surface_id: 'telegram-ops', surface_revision: 1, bot_id: 7_463_512_990,
        update_id: update.fetch('update_id'), raw_payload_hash: transport.digest_of(update)
      )
    )
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
  # reads the conversation history and it rides the second turn's payload.
  def test_a_follow_up_message_queues_and_carries_the_transcript
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      start = Time.utc(2026, 8, 10, 12, 0, 0)
      first = update(101, text: 'make it blue')
      second = update(102, text: 'and the font?')
      transport.batch([first])

      assert_equal :served, gateway.serve_once(now: start)

      transport.batch([second])

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
      first_ref = request_ref(first, transport)

      assert_equal "Received #{first_ref}.", replies.first
      assert_equal "Received #{request_ref(second, transport)}.", replies.last
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

  def test_accepted_control_is_unowned_when_terminal_request_delivery_succeeds
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      now = Time.utc(2026, 8, 10, 12, 0, 0)
      transport.batch([update(1, text: 'work')])

      assert_equal :served, gateway.serve_once(now:, drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      request_id = checkpoints.request_history(thread_id: thread).first.request_id
      accepted = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                       .find { |row| row.fetch('kind') == 'accepted' }
      assert_nil accepted.fetch('request_id')

      terminal = Comms::Delivery.build(
        conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'answer',
        part_index: 0, part_count: 1, journaled: true, render_version: 1,
        content_digest: 'd' * 64
      ).wire
      assert_equal :appended, store.append_delivery(
        terminal, surface_id: 'telegram-ops', capacity: 500,
        reserved_request_id: request_id, now:
      )
      assert_equal :claimed, store.claim_delivery(
        delivery_id: terminal.fetch('delivery_id'), owner: 'status-test', fence: 1,
        claim_expires_at: now + 30, now:
      )
      assert_equal :marked, store.mark_delivery(
        delivery_id: terminal.fetch('delivery_id'), owner: 'status-test', fence: 1,
        status: 'succeeded', receipt: { 'message_id' => 42 }, now:
      )

      status = store.request_status(
        surface_id: 'telegram-ops', conversation_id: 'telegram:chat:22222222',
        ref: "r#{request_id[0, 10]}", now:
      )
      assert_equal 'succeeded', status.fetch('delivery_state')
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

  def test_clarification_reply_matching_requires_a_positive_integer_receipt_id
    with_gateway do |gateway, transport, _store|
      row = nil
      gateway.instance_variable_get(:@store).define_singleton_method(:outbox_row_for_receipt) do |
        surface_id:, conversation_id:, message_id:|
        row
      end
      envelope = transport.normalize(update(1, text: 'answer')).merge('reply_to' => 4242)
      markup = JSON.generate(
        'phase' => 'clarification_required', 'request_ref' => 'r0123456789', 'actions' => ['answer']
      )

      [
        {},
        { 'message_id' => 'not-a-number' },
        { 'message_id' => '4242' },
        { 'message_id' => {} },
        { 'message_id' => [] }
      ].each do |receipt|
        row = { 'conversation_id' => envelope.fetch('conversation_id'), 'kind' => 'control',
                'markup' => markup, 'receipt' => JSON.generate(receipt) }

        assert_nil gateway.send(:clarification_reply_reference, envelope), receipt.inspect
      end

      row = { 'conversation_id' => envelope.fetch('conversation_id'), 'kind' => 'control',
              'markup' => markup, 'receipt' => JSON.generate('message_id' => 4242) }

      assert_equal 'r0123456789', gateway.send(:clarification_reply_reference, envelope)
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

  # After /new rotates the generation, /cancel targets the CURRENT
  # generation's thread — the same derivation admission uses — so the live
  # request there is cancelled and work on the pre-rotation thread is never
  # touched.
  def test_cancel_after_a_rotation_affects_only_the_current_generation
    with_gateway do |gateway, transport, store, _adapter, checkpoints, appended|
      seed_binding(store)
      old_thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      transport.batch([update(1, text: 'work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(2, text: '/new')])
      assert_equal :served, gateway.serve_once(drain: false)
      new_thread = Comms::Admission.thread_id(
        'telegram-ops', 'telegram:chat:22222222',
        generation: store.conversation_generation(surface_id: 'telegram-ops',
                                                  conversation_id: 'telegram:chat:22222222')
      )

      refute_equal old_thread, new_thread, 'the rotation must derive a fresh thread'
      transport.batch([update(3, text: 'more work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(4, text: '/cancel')])
      assert_equal :served, gateway.serve_once(drain: false)

      request = checkpoints.request_history(thread_id: new_thread).find { |entry| entry.operation == :turn }
      expected_ref = Tamoz::Comms::Lifecycle::RequestRef.for(request.request_id)
      assert_equal "Cancellation requested for #{expected_ref}.", appended.last.fetch('text')
      assert_equal 1, cancellation_stamped_count(store, new_thread),
                   'the live request on the CURRENT generation is stamped'
      assert_equal 0, cancellation_stamped_count(store, old_thread),
                   'the pre-rotation request keeps running untouched'
      assert_empty checkpoints.request_history(thread_id: old_thread)
                      .select { |request| request.operation == :redirect },
                   'no cancel operation lands on the old thread'
      assert_equal %i[turn redirect], checkpoints.request_history(thread_id: new_thread).map(&:operation)
    end
  end

  # Nothing admitted on the current generation means /cancel refuses
  # honestly instead of queueing an operation against a stale thread.
  def test_cancel_with_no_running_work_on_the_current_generation_refuses_bounded
    with_gateway do |gateway, transport, store, _adapter, checkpoints, appended|
      seed_binding(store)
      old_thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')
      transport.batch([update(1, text: 'work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(2, text: '/new'), update(3, text: '/cancel')])
      assert_equal :served, gateway.serve_once(drain: false)

      assert_equal Tamoz::Comms::Gateway::CANCEL_NO_WORK_REPLY, appended.last.fetch('text')
      assert_equal 0, cancellation_stamped_count(store, old_thread),
                   'the pre-rotation request is neither stamped nor redirected'
      assert_equal [:turn], checkpoints.request_history(thread_id: old_thread).map(&:operation)
    end
  end

  # Aggregate /status projects the active request on the thread it was
  # ADMITTED to, so after a rotation it reports the real task state instead
  # of a not_started mismatch (phase-1 blind spot).
  def test_aggregate_status_reports_the_current_generation_after_a_rotation
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(1, text: 'work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(2, text: '/new'), update(3, text: 'more work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(4, text: '/status')])
      assert_equal :served, gateway.serve_once(drain: false)

      status_reply = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                          .map { |row| row.fetch('text') }
                          .reverse.find { |text| text.start_with?('Work status:') }

      assert_match(/State: queued/, status_reply, 'the aggregate names the live state of the rotated request')
      refute_match(/State: accepted/, status_reply)
    end
  end

  def cancellation_stamped_count(store, thread_id)
    store.__send__(:read, 'test.gateway.cancel.stamp.count') do |txn|
      txn.scalar('test.gateway.cancel.stamp.count', <<~SQL, [thread_id]).to_i
        SELECT COUNT(*) FROM tamoz_comms_requests
        WHERE thread_id = ? AND cancellation_requested_at_ms IS NOT NULL
      SQL
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

  # The poison-argument surface is frozen: a /think argument of ~1400 CJK
  # characters gets the FIXED short refusal — never the session layer's
  # ArgumentError text, which would echo the raw argument bytes back.
  def test_an_oversized_cjk_think_argument_gets_the_fixed_bounded_refusal
    controls = ScriptedControls.new
    with_gateway(controls: ->(_thread) { controls }) do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(1, text: 'work')])
      gateway.serve_once(drain: false)
      transport.batch([update(2, text: "/think #{'思' * 1400}")])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last.fetch('text')

      assert_equal 'Reasoning depth must be low, medium, or high.', reply
      refute_includes(reply, '思')
      assert_operator reply.bytesize, :<=, Comms::Delivery::MAX_TEXT_BYTES
      assert_empty controls.calls, 'the refused preference executes no control'
    end
  end

  def test_a_bad_verbose_argument_gets_its_own_fixed_bounded_refusal
    controls = ScriptedControls.new
    with_gateway(controls: ->(_thread) { controls }) do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(1, text: 'work')])
      gateway.serve_once(drain: false)
      transport.batch([update(2, text: "/verbose #{'大' * 1400}")])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last.fetch('text')

      assert_equal 'Answer verbosity must be quiet, normal, or detailed.', reply
      assert_operator reply.bytesize, :<=, Comms::Delivery::MAX_TEXT_BYTES
    end
  end

  # Belt-and-braces at the single choke point: whatever a control handler
  # produced, the delivery build can never raise on reply length.
  def test_append_control_clamps_oversized_reply_text_to_the_delivery_ceiling
    with_gateway do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      envelope = transport.normalize(update(1, text: '/help'))

      gateway.send(:append_control, '字' * 5000, envelope, now: Time.utc(2026, 8, 10, 12, 0, 0))

      reply = appended.last.fetch('text')

      assert_operator reply.bytesize, :<=, Comms::Delivery::MAX_TEXT_BYTES,
                      'a delivery build can never raise from control-reply length'
    end
  end

  def test_every_fixed_control_reply_constant_fits_the_delivery_ceiling
    replies = Tamoz::Comms::Gateway.constants.sort
                                         .filter_map { |name| Tamoz::Comms::Gateway.const_get(name) }
                                         .select { |value| value.is_a?(String) }

    refute_empty replies
    replies.each do |reply|
      assert_operator reply.bytesize, :<=, Comms::Delivery::MAX_TEXT_BYTES,
                      "#{reply.inspect} exceeds Delivery::MAX_TEXT_BYTES"
    end
  end

  # The declared inbound limit covers COMMAND/control-kind updates too: an
  # oversized command refuses typed with the same bounded wording as an
  # oversized message and creates no request row.
  def test_an_oversized_command_refuses_with_the_bounded_reply_and_no_request_row
    with_gateway(limits: { max_inbound_bytes: 32 }) do |gateway, transport, store, _adapter, checkpoints|
      seed_binding(store)
      transport.batch([update(330, text: "/status #{'x' * 40}")])

      assert_equal :served, gateway.serve_once(drain: false)

      thread = Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_equal [%w[rejected inbound_too_large]], inbound_dispositions(store, 330)
      assert_equal 0, request_row_count(store), 'the oversized command creates no request row'
      assert_empty checkpoints.request_history(thread_id: thread)
      replies = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
                     .select { |row| row.fetch('kind') == 'control' }

      assert_equal ["That message exceeds this channel's size limit."], replies.map { |row| row.fetch('text') }
    end
  end

  def test_a_within_limit_command_still_passes_the_size_gate
    with_gateway(limits: { max_inbound_bytes: 32 }) do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(331, text: '/help')])

      assert_equal :served, gateway.serve_once(drain: false)

      assert_equal [%w[ignored command]], inbound_dispositions(store, 331)
      assert_equal Tamoz::Comms::Gateway::HELP_REPLY, appended.last.fetch('text')
    end
  end

  def test_help_teaches_the_core_loop_and_keeps_default_controls_short
    with_gateway do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(332, text: '/help')])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last.fetch('text')
      assert_match(/Example:.*\/status.*\/cancel/i, reply)
      assert_includes reply, 'More: /help more.'
      refute_match(%r{/think|/verbose|/usage|/context}, reply)
      assert_operator reply.scan(%r{/[a-z]+(?:\s|$)}i).uniq.length, :<=, 5
    end
  end

  def test_help_more_expands_the_typed_command_reference_and_rejects_other_arguments
    with_gateway do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(333, text: '/help more')])

      assert_equal :served, gateway.serve_once(drain: false)

      reply = appended.last.fetch('text')
      assert_equal Tamoz::Comms::Gateway::HELP_MORE_REPLY, reply
      assert_includes reply, '/redirect r<reference> <new task>'
      assert_includes reply, '/think <low|medium|high>'
      assert_includes reply, '/verbose <quiet|normal|detailed>'

      transport.batch([update(334, text: '/help unexpected')])
      assert_equal :served, gateway.serve_once(drain: false)

      assert_equal Tamoz::Comms::Gateway::HELP_USAGE_REPLY, appended.last.fetch('text')
    end
  end

  # A replayed control update already has its disposition durable and its
  # command applied; re-running it would double /new generations. The replay
  # records nothing new and answers nothing new.
  def test_a_replayed_new_command_bumps_the_generation_once_only
    with_gateway do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(1, text: 'work')])
      assert_equal :served, gateway.serve_once(drain: false)

      transport.batch([update(2, text: '/new')])
      assert_equal :served, gateway.serve_once(drain: false)
      generation = store.conversation_generation(surface_id: 'telegram-ops',
                                                 conversation_id: 'telegram:chat:22222222')

      transport.batch([update(2, text: '/new')])
      assert_equal :served, gateway.serve_once(drain: false)

      assert_equal generation, store.conversation_generation(surface_id: 'telegram-ops',
                                                             conversation_id: 'telegram:chat:22222222'),
                   'a replayed /new must not bump the generation twice'
      assert_equal 1, inbound_rows_count(store, 2), 'the replay inserts no second anchor row'
    end
  end

  def test_a_replayed_context_control_executes_its_command_once
    controls = ScriptedControls.new
    with_gateway(controls: ->(_thread) { controls }) do |gateway, transport, store|
      seed_binding(store)
      transport.batch([update(3, text: 'work')])
      gateway.serve_once(drain: false)

      transport.batch([update(4, text: '/think high')])
      gateway.serve_once(drain: false)
      transport.batch([update(4, text: '/think high')])
      gateway.serve_once(drain: false)

      assert_equal [[:think, 'high']], controls.calls,
                   'the replayed command must not execute a second time'
    end
  end

  # The stateless thread keeps the existing guidance line; a REAL fence
  # conflict from the controls seam answers the distinct bounded busy line.
  def test_a_stateless_thread_keeps_the_guidance_reply_on_a_read_only_control
    controls = ConflictControls.new('thread tg.g1 has no checkpoint')
    with_gateway(controls: ->(_thread) { controls }) do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(5, text: 'work')])
      gateway.serve_once(drain: false)

      transport.batch([update(6, text: '/context')])
      gateway.serve_once(drain: false)

      assert_equal Tamoz::Comms::Gateway::CONTROLS_NO_SESSION_REPLY, appended.last.fetch('text')
    end
  end

  def test_a_real_fence_conflict_answers_the_distinct_conflict_reply
    controls = ConflictControls.new('writer lease for thread tg.g1 is held by owner tamoz.worker/9')
    with_gateway(controls: ->(_thread) { controls }) do |gateway, transport, store, _adapter, _checkpoints, appended|
      seed_binding(store)
      transport.batch([update(7, text: 'work')])
      gateway.serve_once(drain: false)

      transport.batch([update(8, text: '/context')])
      gateway.serve_once(drain: false)

      reply = appended.last.fetch('text')

      assert_equal Tamoz::Comms::Gateway::CONTROLS_CONFLICT_REPLY, reply
      refute_equal Tamoz::Comms::Gateway::CONTROLS_NO_SESSION_REPLY, reply
    end
  end

  def inbound_rows_count(store, update_id)
    store.__send__(:read, 'test.gateway.inbound.count') do |txn|
      txn.scalar('test.gateway.inbound.count', 'SELECT COUNT(*) FROM tamoz_comms_inbound WHERE update_id = ?',
                 [update_id]).to_i
    end
  end

  private

  def build_checkpoints(adapter)
    gateway_graph('gateway-2').compile(checkpointer: adapter).checkpointer
  end

  # The single-node gateway graph both harness paths compile; `name` keys the
  # graph and its node implementation so the two callers stay distinct.
  def gateway_graph(name)
    Tamoz.graph(name:, version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: "#{name}.finish", version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  # A scripted session-controls seam for gateway-level control tests: the
  # real SessionContextControls validation semantics (typed ArgumentError on
  # a bad preference) without constructing a Session.
  class ScriptedControls
    attr_reader :calls

    def initialize
      @calls = []
    end

    def set_reasoning_depth(thread:, request_id:, depth:)
      unless %w[low medium high].include?(depth)
        raise ArgumentError, "reasoning_depth must be one of low, medium, high (got #{depth.inspect})"
      end

      @calls << [:think, depth]
      projection('think')
    end

    def set_answer_verbosity(thread:, request_id:, verbosity:)
      unless %w[quiet normal detailed].include?(verbosity)
        raise ArgumentError, "answer_verbosity must be one of quiet, normal, detailed (got #{verbosity.inspect})"
      end

      @calls << [:verbose, verbosity]
      projection('verbose')
    end

    def projection(control)
      Struct.new(:document).new('control' => control, 'generation' => 1,
                                'preferences' => {}, 'truncated_fragments' => 0)
    end
  end

  # A controls seam that raises the checkpoint-conflict class with a chosen
  # message: the stateless wording keeps the guidance line, everything else
  # is a real fence conflict.
  class ConflictControls
    def initialize(message)
      @message = message
    end

    def context_report(thread:)
      raise Tamoz::CheckpointConflictError, @message
    end
  end

  # A scripted Transport for the loop: batches of raw updates, optional
  # receipt, optional ambiguity.
  class ScriptedTransport
    attr_accessor :receipt, :raise_ambiguous, :transient_polls, :comms_errors, :authenticated_id

    def initialize
      @updates = []
      @transient_polls = 0
      @comms_errors = 0
      @poll_calls = 0
      @authenticated_id = nil
      @authentication_calls = 0
    end

    attr_reader :authentication_calls, :poll_calls

    def authenticate(descriptor, _credential)
      @authentication_calls += 1
      { 'id' => @authenticated_id || descriptor.identity.fetch(:expected_bot_id) }
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
