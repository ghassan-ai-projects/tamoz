# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/outbox_sink_fixtures'

# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
class AgentOutboxDeliverySinkTest < Minitest::Test
  include OutboxSinkFixtures

  def test_a_worker_event_appends_bounded_deliveries
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      result = sink.push(thread_id: 'telegram.ops.abc', kind: 'request.completed', text: 'here is the answer')

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
        sink.push(thread_id: 'telegram.ops.abc', kind:, text: 'result text', request_id: "terminal-#{index}")

        assert_equal 'result text',
                     store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending]).last.fetch('text')
      end
    end
  end

  def test_progress_events_are_not_chat_messages
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      %w[request.accepted request.claimed request.running request.waiting request.recovered].each do |kind|
        assert_nil sink.push(thread_id: 'telegram.ops.abc', kind:, text: 'working', request_id: 'occurrence-1')
      end
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end

  def test_long_output_is_split_into_bounded_parts
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      sink.push(thread_id: 'telegram.ops.abc', kind: 'request.completed', text: 'x' * 250)

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

      assert_equal :accepted, sink.push(thread_id: 'telegram.ops.abc', kind: 'request.completed', text: 'نعم ☀️ ' * 900)
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal 2, rows.length
      assert_operator rows.first.fetch('text').bytesize, :>, 4096
    end
  end

  def test_a_healing_escalation_is_one_control_notice_per_request
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)
      event = { thread_id: 'telegram.ops.abc', kind: 'healing.escalated', text: 'it needs you',
                request_id: 'occurrence-1' }

      assert_equal :accepted, sink.push(event)
      sink.push(event)
      rows = store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])

      assert_equal([['control', 'it needs you']], rows.map { |row| [row.fetch('kind'), row.fetch('text')] })
    end
  end

  def test_clarification_delivery_reports_capacity_refusal
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store, surface: descriptor(limits: {
                                                               max_inbound_bytes: 8192, max_open_requests: 50,
                                                               max_denial_prompts_per_request: 4,
                                                               outbox_capacity: 1, control_capacity: 50,
                                                               per_chat_messages_per_s: 1.0,
                                                               global_messages_per_s: 25.0
                                                             }))
      interrupts = [{ task_id: 'task', call_index: 0,
                      descriptor: { 'kind' => 'clarify', 'question' => 'Which file?' } }]

      result = sink.push(
        thread_id: 'telegram.ops.abc', kind: 'request.clarification_request', request_id: 'occurrence-1',
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
        sink.push(thread_id: 'telegram.ops.abc', kind: 'request.completed', text: 'hello',
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
      event = { thread_id: 'telegram.ops.abc', kind: 'request.completed', text: 'done', request_id: 'occurrence-1' }

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
      result = sink.push(thread_id: 'telegram.unbound', kind: 'request.completed', text: 'hi')

      assert_nil result
      assert_empty store_for(adapter, checkpoints)
        .outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end

  def test_unknown_event_kinds_are_skipped
    with_engine do |sink, adapter, checkpoints|
      store = store_for(adapter, checkpoints)
      bind_thread_to_conversation(store)

      assert_nil sink.push(thread_id: 'telegram.ops.abc', kind: 'internal.step', text: 'x')

      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end

  def test_the_default_worker_runtime_sink_is_nil_safe
    with_engine do |_sink, adapter, checkpoints|
      store = adapter.bind_comms_store(checkpoints)
      sink = Tamoz::Comms::OutboxDeliverySink.new(adapter:, checkpoints:)

      assert_nil sink.push(thread_id: 'telegram.x', kind: 'request.completed', text: '')
      assert_empty store.outbox_rows(surface_id: 'telegram-ops', statuses: %w[pending])
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
