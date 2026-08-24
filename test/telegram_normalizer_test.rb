# frozen_string_literal: true

require_relative 'test_helper'

# Phase 0 identity (plan 01, work items 2–3): the Telegram digest covers the
# MEANINGFUL normalized content — not just update_id — so identical bytes
# dedup and any content change under one update_id is a detectable integrity
# conflict; and update_id / message_id / reply_to / callback_message_id stay
# distinct fields carrying their intended values. Fixture updates use
# DISTINCT update_id vs message_id values so a mixup cannot hide.
class TelegramNormalizerTest < Minitest::Test
  def normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)

  def message_update(update_id:, message_id:, text: 'hello', reply_to: nil)
    {
      'update_id' => update_id,
      'message' => {
        'message_id' => message_id,
        'date' => 1_752_700_800,
        'chat' => { 'id' => 222_222_22, 'type' => 'private' },
        'from' => { 'id' => 111_111_11 },
        'text' => text
      }.tap do |body|
        body['reply_to_message'] = { 'message_id' => reply_to } if reply_to
      end
    }
  end

  # Same bytes normalized twice MUST collide on the same digest — that is
  # the dedup key admission compares.
  def test_the_digest_is_stable_for_identical_updates
    first = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire.fetch('raw_payload_hash')
    second = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire.fetch('raw_payload_hash')

    assert_equal first, second
    assert_match(/\A[0-9a-f]{64}\z/, first)
  end

  # Invariant 1: any meaningful change under one update_id produces a
  # DIFFERENT digest — the durable integrity-conflict signal. The old
  # update_id-only digest could not see any of these.
  def test_a_meaningful_content_change_changes_the_digest
    base = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire.fetch('raw_payload_hash')

    rewritten = normalizer.normalize(
      message_update(update_id: 5001, message_id: 42, text: 'goodbye')
    ).wire.fetch('raw_payload_hash')

    refute_equal base, rewritten, 'a text change must change the digest'

    quoted = normalizer.normalize(
      message_update(update_id: 5001, message_id: 42, reply_to: 77)
    ).wire.fetch('raw_payload_hash')

    refute_equal base, quoted, 'a quoted reply_to change must change the digest'
  end

  def test_message_and_command_kinds_carry_their_own_telegram_message_id
    text = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire

    assert_equal 42, text.fetch('message_id')
    refute_equal 5001, text.fetch('message_id'), 'message_id and update_id are different fields'

    command = normalizer.normalize(
      message_update(update_id: 5002, message_id: 43, text: '/help')
    ).wire

    assert_equal 'command', command.fetch('kind')
    assert_equal 43, command.fetch('message_id')
  end

  def test_the_envelope_wire_round_trips_the_message_id
    wire = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire

    assert_equal 42, Tamoz::Comms::InboundEnvelope.from_wire(wire).message_id
  end

  # Contract §7.1: a callback binds the id of the message the buttons are
  # attached to — never its own update_id, never a fresh message id.
  def test_callback_preserves_the_originating_message_id_and_digests_its_fields
    callback = { 'update_id' => 5003,
                 'callback_query' => { 'id' => 'q-9', 'from' => { 'id' => 111_111_11 },
                                       'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                                      'message_id' => 2001 },
                                       'data' => 'deny:abc' } }
    wire = normalizer.normalize(callback).wire

    assert_equal 2001, wire.fetch('callback_message_id')
    refute_equal 5003, wire.fetch('callback_message_id')
    digest = wire.fetch('raw_payload_hash')

    replayed = normalizer.normalize(callback).wire.fetch('raw_payload_hash')
    changed = normalizer.normalize(
      callback.merge('callback_query' => callback.fetch('callback_query').merge('data' => 'approve:abc'))
    ).wire.fetch('raw_payload_hash')

    assert_equal digest, replayed, 'identical callback bytes keep one digest'
    refute_equal digest, changed, 'a callback data change must change the digest'
  end

  def test_membership_digests_deterministically_beyond_update_id
    member = lambda do |update_id|
      { 'update_id' => update_id,
        'my_chat_member' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                              'from' => { 'id' => 111_111_11 } } }
    end

    first = normalizer.normalize(member.call(5004)).wire.fetch('raw_payload_hash')
    second = normalizer.normalize(member.call(5004)).wire.fetch('raw_payload_hash')

    assert_equal first, second
  end

  def test_an_unsupported_update_still_digests_deterministically
    unsupported = ->(update_id) { { 'update_id' => update_id, 'poll_answer' => { 'option_ids' => [1] } } }

    first = normalizer.normalize(unsupported.call(5005)).wire.fetch('raw_payload_hash')
    second = normalizer.normalize(unsupported.call(5005)).wire.fetch('raw_payload_hash')

    assert_equal first, second
    assert_equal 'unsupported', normalizer.normalize(unsupported.call(5005)).wire.fetch('kind')
  end

  # Work item 3: all four telegram ids are carried at once and stay distinct
  # on ONE envelope.
  def test_all_four_identity_fields_stay_distinct_on_one_envelope
    wire = normalizer.normalize(
      message_update(update_id: 5006, message_id: 46, reply_to: 45)
    ).wire

    assert_equal 5006, wire.fetch('update_id')
    assert_equal 46, wire.fetch('message_id')
    assert_equal 45, wire.fetch('reply_to')
    assert_nil wire.fetch('callback_message_id')
    assert_equal [5006, 46, 45], [wire.fetch('update_id'), wire.fetch('message_id'), wire.fetch('reply_to')].uniq,
                 'the three ids must be distinct values on this fixture'

    callback = normalizer.normalize(
      'update_id' => 5007,
      'callback_query' => { 'id' => 'q-10', 'from' => { 'id' => 111_111_11 },
                            'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                                           'message_id' => 2002 },
                            'data' => 'deny:abc' }
    ).wire

    assert_equal [5007, 2002], [callback.fetch('update_id'), callback.fetch('callback_message_id')]
  end
end
