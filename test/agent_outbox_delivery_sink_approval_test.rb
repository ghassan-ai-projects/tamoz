# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/outbox_sink_fixtures'

class AgentOutboxDeliverySinkApprovalTest < Minitest::Test
  include OutboxSinkFixtures

  def test_repeated_approval_occurrences_create_distinct_deliveries
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      interrupts = [{ task_id: 'task', call_index: 0,
                      descriptor: { 'kind' => 'approve_tool',
                                    'decision' => { 'required_evidence' => 'filesystem_operator' } } }]

      2.times do |index|
        result = sink.push(
          thread_id: 'telegram.ops.abc', kind: 'request.approval_request', text: 'Approval requested.',
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
    { thread_id: 'telegram.ops.abc', kind: 'request.approval_request', text: 'Approval requested.',
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
    end
  end

  def test_approval_card_ends_with_the_safe_next_step_and_hides_internals
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      sink.push(approval_event('occurrence-1'))
      text = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).first.fetch('text')

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

      assert_operator text.length, :<=, 20
      assert_equal [1, Comms::Rendering.content_digest(text)], [rows.length, rows.first.fetch('content_digest')]
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
      prompt = store.prompt(reference_digest: reference_digest(markup))

      assert_equal ['chat_bound', %w[approve deny]], [prompt.fetch('required_evidence'), markup.fetch('actions')],
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

      assert_equal [1, 'control'], [rows.length, rows.first.fetch('kind')]
      assert_match(/approvals are not enabled/, rows.first.fetch('text'))
    end
  end

  def test_the_approvals_disabled_notice_is_deduped_per_occurrence
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(
        store, surface: descriptor(approvals: { mode: 'none', prompt_ttl_s: 900 })
      )

      2.times { sink.push(approval_event('occurrence-1')) }

      assert_equal 1, store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).length,
                   'the notice is deduped per occurrence'
    end
  end

  def reference_digest(markup)
    Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, markup.fetch('reference'))
  end
end
