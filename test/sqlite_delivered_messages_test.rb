# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class SQLiteDeliveredMessagesTest < Minitest::Test
  Comms = Tamoz::Comms

  def test_recent_rows_and_every_live_card_come_back_oldest_first
    Dir.mktmpdir do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      store = adapter.bind_comms_store
      live, = card(store, 'live', at: Time.utc(2026, 10, 9, 10))
      _, consumed = card(store, 'consumed', at: Time.utc(2026, 10, 9, 10, 1))
      decision = Comms::DecisionRecord.build(
        thread_id: 'tk.talk.consumed', occurrence_id: 'consumed', interrupts: [],
        interrupt_digest: consumed.interrupt_digest, direction: 'deny', actor_kind: 'talk_user', actor_id: 'talk:user:1',
        source: 'talk', decided_at: Time.utc(2026, 10, 9, 10, 2), ttl_s: 900
      )

      assert_equal :consumed, store.consume_prompt(reference_digest: consumed.reference_digest,
                                                   decision_wire: decision.wire, now: Time.utc(2026, 10, 9, 10, 2))
      5.times { |index| deliver(store, "recent #{index}", at: Time.utc(2026, 10, 9, 11, index)) }
      deliver(store, 'other surface', at: Time.utc(2026, 10, 9, 12), surface_id: 'elsewhere')

      texts = store.delivered_messages(surface_id: 'talk', limit: 3).map { |row| row.fetch('text') }

      assert_equal ["card #{live}", 'recent 2', 'recent 3', 'recent 4'], texts
    ensure
      adapter&.close
    end
  end

  def card(store, name, at:)
    reference, prompt = Comms::ApprovalPrompt.build(
      surface_id: 'talk', surface_revision: 1, thread_id: "tk.talk.#{name}", occurrence_id: name,
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      required_evidence: :chat_bound, correspondent_id: 'talk:user:1', conversation_id: 'talk:chat:1',
      prompt_ttl_s: 900, created_at: at
    )
    store.insert_prompt(prompt.wire)
    id = deliver(store, "card #{name}", at:, markup: JSON.generate('reference' => reference))
    store.activate_prompt(reference_digest: prompt.reference_digest, now: at, receipt: id.to_s)
    [name, prompt]
  end

  def deliver(store, text, at:, surface_id: 'talk', markup: nil)
    @id = (@id || 1000) + 1
    kind = markup ? 'approval_request' : 'answer'
    wire = Comms::Delivery.build(conversation_id: 'talk:chat:1', kind:, text:, render_version: 1,
                                 content_digest: Digest::SHA256.hexdigest(text), markup:).wire
    store.append_delivery(wire, surface_id:, capacity: 50, reserved_request_id: nil, now: at)
    claimed = store.claim_delivery(delivery_id: wire.fetch('delivery_id'), owner: 'test', fence: 1,
                                   claim_expires_at: at + 30, now: at)
    raise "not claimed: #{claimed}" unless claimed == :claimed

    store.mark_delivery(delivery_id: wire.fetch('delivery_id'), owner: 'test', fence: 1, status: 'succeeded', now: at,
                        receipt: { 'message_id' => @id })
    @id
  end
end
