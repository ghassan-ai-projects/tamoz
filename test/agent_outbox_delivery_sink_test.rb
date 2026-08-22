# frozen_string_literal: true

require_relative 'test_helper'

# Slice E (COMMS_TELEGRAM_PLAN §3) — the worker's DeliverySink projection:
# lifecycle events become bounded outbox rows via the CommsStore, an unbound
# thread delivers nothing (nil-safe), and the worker pushes before the
# occurrence closes.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
class AgentOutboxDeliverySinkTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_engine
    Dir.mktmpdir('tamoz-sink') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'sink', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'sink.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        sink = Tamoz::Agent::OutboxDeliverySink.new(adapter:, checkpoints:)
        yield sink, adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  def store_for(adapter, checkpoints)
    adapter.bind_comms_store(checkpoints)
  end

  def descriptor(**overrides)
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990 },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 100, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 },
      **overrides
    )
  end

  def bind_thread_to_conversation(store, thread: 'tg.ops.abc', surface: descriptor)
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    store.deploy_surface(surface.wire, now:)
    store.bind_correspondent(binding_wire(now), now:)
    envelope = Comms::InboundEnvelope.new(
      surface_id: 'telegram-ops', surface_revision: 1, update_id: 1,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      text: 'hello', observed_time: now
    ).wire
    store.admit_and_enqueue(
      envelope, surface_id: 'telegram-ops', bot_id: 7_463_512_990,
                thread:, profile_id: 'ops', reservation: 1, capacity: 500, now:
    )
  end

  def binding_wire(now)
    Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      bound_at: now, bound_by: 'operator:test'
    ).wire
  end

  def test_a_worker_event_appends_bounded_deliveries
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      result = sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'here is the answer')

      assert_equal :accepted, result
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 1, rows.length
      assert_equal 'answer', rows.first.fetch('kind')
      assert_equal 'here is the answer', rows.first.fetch('text')
    end
  end

  def test_long_output_is_split_into_bounded_parts
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'x' * 250)

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 3, rows.length
      rows.each do |row|
        assert_operator row.fetch('text').length, :<=, 100
      end
      assert_equal([0, 1, 2], rows.map { |row| row.fetch('part_index') })
    end
  end

  def test_repeated_approval_occurrences_create_distinct_deliveries
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      interrupts = [{ task_id: 'task', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }]

      2.times do |index|
        result = sink.push(
          thread_id: 'tg.ops.abc', kind: 'request.approval_request', text: 'Approval requested.',
          request_id: "occurrence-#{index + 1}", interrupts:
        )

        assert_equal :accepted, result
      end

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 2, rows.length
      assert_equal 2, rows.map { |row| row.fetch('delivery_id') }.uniq.length
    end
  end

  def approval_event(request_id)
    { thread_id: 'tg.ops.abc', kind: 'request.approval_request', text: 'Approval requested.',
      request_id:,
      interrupts: [{ task_id: 'task', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }] }
  end

  # ADR-049 Phase 5 (defense in depth): under the v1 policy every interrupt
  # requires filesystem_operator evidence, so the rendered keyboard offers
  # Deny only — the markup reflects the policy, never a hardcoded list. A
  # stray approve callback is still refused by the Phase 3 gate; the button's
  # absence is UX, not the security boundary.
  def test_an_approval_request_renders_a_deny_only_keyboard_under_v1_policy
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(approval_event('occurrence-1'))
      row = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first

      markup = JSON.parse(row.fetch('markup'))

      assert_equal %w[deny], markup.fetch('actions'),
                   'a v1-policy prompt must not render an approve button (ADR-049 INV-D)'
      assert_match(/\A[0-9a-f]{32}\z/, markup.fetch('reference'))
    end
  end

  # A turn parked on approval on a surface where approvals are DISABLED used
  # to go silent: no prompt machinery, no message, every later message
  # queueing behind a pause the correspondent could not see. The sink owes
  # the channel a notice instead — control, not terminal, and deduped per
  # occurrence so a worker restart never double-tells.
  def test_an_approval_request_on_a_surface_without_approvals_delivers_a_notice
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(
        store, surface: descriptor(approvals: { mode: 'none', prompt_ttl_s: 900 })
      )

      assert_equal :accepted, sink.push(approval_event('occurrence-1'))
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 1, rows.length
      assert_equal 'control', rows.first.fetch('kind')
      assert_match(/approvals are not enabled/, rows.first.fetch('text'))

      sink.push(approval_event('occurrence-1'))

      assert_equal 1, store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).length,
                   'the notice is deduped per occurrence'
    end
  end

  # Two occurrences that honestly produce the same answer text must BOTH
  # deliver: content-addressed dedup covers the crash re-push of ONE
  # occurrence, never two different requests that said the same thing.
  def test_identical_answers_from_different_occurrences_both_deliver
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      2.times do |index|
        sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'hello',
                  request_id: "occurrence-#{index + 1}")
      end

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 2, rows.length
    end
  end

  def test_a_terminal_delivery_replay_after_sink_restart_is_one_row
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      event = { thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'done', request_id: 'occurrence-1' }

      assert_equal :accepted, sink.push(event)
      restarted_sink = Tamoz::Agent::OutboxDeliverySink.new(adapter:, checkpoints:)
      assert_equal :accepted, restarted_sink.push(event)

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
      assert_equal 1, rows.length
      assert_equal 'answer', rows.first.fetch('kind')
      assert_equal rows.first.fetch('delivery_id'),
                   Comms::Delivery.build(
                     conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'done',
                     part_index: 0, part_count: 1, journaled: true, render_version: 1,
                     content_digest: Comms::Rendering.content_digest('done'),
                     identity_key: 'occurrence-1'
                   ).delivery_id
    end
  end

  def test_an_unbound_thread_delivers_nothing
    with_engine do |sink, adapter, checkpoints|
      result = sink.push(thread_id: 'tg.unbound', kind: 'request.completed', text: 'hi')

      assert_nil result
      assert_empty store_for(adapter, checkpoints)
        .outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end

  def test_unknown_event_kinds_are_skipped
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_nil sink.push(thread_id: 'tg.ops.abc', kind: 'internal.step', text: 'x')

      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end

  def test_the_default_worker_runtime_sink_is_nil_safe
    with_engine do |_sink, adapter, checkpoints|
      store = adapter.bind_comms_store(checkpoints)
      sink = Tamoz::Agent::OutboxDeliverySink.new(adapter:, checkpoints:)

      assert_nil sink.push(thread_id: 'tg.x', kind: 'request.completed', text: '')
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
