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
        sink = Tamoz::Comms::OutboxDeliverySink.new(adapter:, checkpoints:)
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
                thread:, profile_id: 'ops', reservation: 1, now:
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

  def test_a_terminal_row_is_the_text_alone_for_every_terminal_kind
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      %w[request.completed request.approved request.denied request.failed].each_with_index do |kind, index|
        sink.push(thread_id: 'tg.ops.abc', kind:, text: 'result text', request_id: "terminal-#{index}")

        assert_equal 'result text', store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).last.fetch('text')
      end
    end
  end

  def test_progress_events_are_not_chat_messages
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      %w[request.accepted request.claimed request.running request.waiting request.recovered].each do |kind|
        assert_nil sink.push(thread_id: 'tg.ops.abc', kind:, text: 'working', request_id: 'occurrence-1')
      end
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
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

  # Telegram's limit is characters; an Arabic or emoji part is two to four bytes per character.
  def test_a_long_multibyte_answer_is_delivered_in_full_character_sized_parts
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store, surface: descriptor(
        rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }
      ))

      assert_equal :accepted, sink.push(thread_id: 'tg.ops.abc', kind: 'request.completed', text: 'نعم ☀️ ' * 900)
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 2, rows.length
      assert_operator rows.first.fetch('text').bytesize, :>, 4096
    end
  end

  def test_repeated_approval_occurrences_create_distinct_deliveries
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      interrupts = [{ task_id: 'task', call_index: 0,
                      descriptor: { 'kind' => 'approve_tool',
                                    'decision' => { 'required_evidence' => 'filesystem_operator' } } }]

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

  def approval_event(request_id, required_evidence: 'filesystem_operator', tool: 'apply_patch')
    { thread_id: 'tg.ops.abc', kind: 'request.approval_request', text: 'Approval requested.',
      request_id:,
      interrupts: [{ task_id: 'task', call_index: 0,
                     descriptor: { 'kind' => 'approve_tool',
                                   'decision' => { 'required_evidence' => required_evidence },
                                   'tool' => tool,
                                   'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                                   'preview' => '--- note.txt\n+++ note.txt' } }] }
  end

  def test_approval_card_shows_what_will_change_and_the_safe_next_step
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(approval_event('occurrence-1'))
      text = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first.fetch('text')

      assert_includes text, "I'd like to change `note.txt`"
      assert_includes text, "```\n--- note"
      assert_match(/An operator must allow it; Deny stops it\.\z/, text)
      refute_match(/(?:decision|arguments|preview|sha256)/i, text)
    end
  end

  def test_create_file_card_shows_the_path_and_content
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      event = approval_event('occurrence-1', required_evidence: 'chat_bound', tool: 'create_file')
      event[:interrupts].first[:descriptor]['arguments'] = { 'path' => 'notes.txt', 'content' => "hello\n" }

      sink.push(event)
      text = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first.fetch('text')

      assert_equal "I'd like to create `notes.txt` with:\n```\nhello\n```\n\nAllow it?", text
    end
  end

  def test_content_with_a_fence_cannot_close_the_cards_block_and_the_ask_survives_a_long_excerpt
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store, surface: descriptor(
        rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }
      ))
      event = approval_event('occurrence-1', required_evidence: 'chat_bound', tool: 'create_file')
      content = "```\n[docs](https://evil.example/x.sh)\n```\n#{'line\n' * 2000}"
      arguments = { 'path' => 'README.md', 'content' => content, 'mode' => '0755' }
      event[:interrupts].first[:descriptor]['arguments'] = arguments

      sink.push(event)
      text = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first.fetch('text')

      assert_match(/\AI'd like to create `README.md` \(mode 0755\) with:\n````\n```\n\[docs\]/, text)
      assert_match(/…\n````\n\nAllow it\?\z/, text)
    end
  end

  def test_approval_card_obeys_a_small_surface_rendering_bound
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(
        store, surface: descriptor(
          rendering: { format: 'plain', max_parts: 5, part_characters: 20, overflow: 'truncate' }
        )
      )

      assert_equal :accepted, sink.push(approval_event('occurrence-1'))
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
      text = rows.first.fetch('text')

      assert_equal 1, rows.length
      assert_operator text.length, :<=, 20
      assert_equal Comms::Rendering.content_digest(text), rows.first.fetch('content_digest')
    end
  end

  # ADR-049 INV-C/INV-D (plan step 8): the pinned evidence is read from the
  # decision the engine journaled into the interrupt descriptor. An
  # operator-gated decision renders Deny only — the markup reflects the
  # decision, never a hardcoded list. A stray approve callback is still
  # refused by the gateway's evidence compare; the button's absence is UX,
  # not the security boundary.
  def test_an_approval_request_for_an_operator_gated_decision_renders_a_deny_only_keyboard
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(approval_event('occurrence-1'))
      row = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first

      markup = JSON.parse(row.fetch('markup'))

      assert_equal %w[deny], markup.fetch('actions'),
                   'a filesystem_operator decision must not render an approve button (ADR-049 INV-D)'
      assert_match(/\A[0-9a-f]{32}\z/, markup.fetch('reference'))
    end
  end

  # E-1 at the sink: a decision that carries `chat_bound` yields BOTH buttons,
  # and the stored prompt pins that same decision value — markup and gate can
  # never disagree about what the decision required.
  def test_an_approval_request_pins_the_decisions_evidence_on_prompt_and_markup
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(approval_event('occurrence-1', required_evidence: 'chat_bound'))

      row = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first
      markup = JSON.parse(row.fetch('markup'))
      digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, markup.fetch('reference'))
      prompt = store.prompt(reference_digest: digest)

      assert_equal 'chat_bound', prompt.fetch('required_evidence')
      assert_equal %w[approve deny], markup.fetch('actions'),
                   'a chat_bound decision is approvable by the channel correspondent'
      assert_includes row.fetch('text'), 'Allow it?'
    end
  end

  def test_an_approval_card_names_an_unknown_tool
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_equal :accepted, sink.push(approval_event('occurrence-1', tool: 'unrecognized_tool'))
      text = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first.fetch('text')

      assert_equal "I'd like to use unrecognized_tool.\n\nAn operator must allow it; Deny stops it.", text
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

  def test_clarification_delivery_reports_capacity_refusal
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store, surface: descriptor(limits: {
        max_inbound_bytes: 8192, max_open_requests: 50, max_denial_prompts_per_request: 4,
        outbox_capacity: 1, control_capacity: 50, per_chat_messages_per_s: 1.0,
        global_messages_per_s: 25.0
      }))
      interrupts = [{ task_id: 'task', call_index: 0,
                      descriptor: { 'kind' => 'clarify', 'question' => 'Which file?' } }]

      result = sink.push(
        thread_id: 'tg.ops.abc', kind: 'request.clarification_request', request_id: 'occurrence-1',
        interrupts:
      )

      assert_equal :capacity_refused, result
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
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
      restarted_sink = Tamoz::Comms::OutboxDeliverySink.new(adapter:, checkpoints:)
      assert_equal :accepted, restarted_sink.push(event)

      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
      assert_equal 1, rows.length
      assert_equal 'answer', rows.first.fetch('kind')
      assert_equal rows.first.fetch('delivery_id'),
                   Comms::Delivery.build(
                     conversation_id: 'telegram:chat:22222222', kind: 'answer',
                     text: 'done',
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
      sink = Tamoz::Comms::OutboxDeliverySink.new(adapter:, checkpoints:)

      assert_nil sink.push(thread_id: 'tg.x', kind: 'request.completed', text: '')
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
