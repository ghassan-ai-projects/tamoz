# frozen_string_literal: true

require_relative 'test_helper'

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

  def parsed_command(subject, update_id, text)
    wire = subject.normalize(message_update(update_id:, message_id: update_id, text:)).wire
    Tamoz::Comms::Commands.parse(wire.fetch('text'))
  end

  def test_a_command_addressed_to_this_bot_drops_the_suffix_and_any_other_bot_keeps_it
    own = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1, bot_username: 'ops_bot')

    assert_equal 'cancel', parsed_command(own, 1, '/cancel@ops_bot now').command
    assert_nil parsed_command(own, 2, '/cancel@other_bot now')
    assert_nil parsed_command(normalizer, 3, '/cancel@ops_bot'), 'without its own name a bot strips no suffix'
  end

  def digest_of(update)
    normalizer.normalize(update).wire.fetch('raw_payload_hash')
  end

  def callback_update(update_id, query_id, message_id, data: 'deny:abc', date: nil)
    message = { 'chat' => { 'id' => 222_222_22, 'type' => 'private' }, 'message_id' => message_id }
    message['date'] = date if date
    { 'update_id' => update_id,
      'callback_query' => { 'id' => query_id, 'from' => { 'id' => 111_111_11 }, 'message' => message,
                            'data' => data } }
  end

  def attachment_of(fields)
    normalizer.normalize(attachment_update(fields)).wire.fetch('attachment')
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

    assert_equal ['command', 43], command.values_at('kind', 'message_id')
  end

  def test_the_envelope_wire_round_trips_the_message_id
    wire = normalizer.normalize(message_update(update_id: 5001, message_id: 42)).wire

    assert_equal 42, Tamoz::Comms::InboundEnvelope.from_wire(wire).message_id
  end

  def test_callback_preserves_the_originating_message_id_and_digests_its_fields
    wire = normalizer.normalize(callback_update(5003, 'q-9', 2001)).wire

    assert_equal [2001, true], [wire.fetch('callback_message_id'), wire.fetch('callback_message_id') != 5003]
    assert_equal wire.fetch('raw_payload_hash'), digest_of(callback_update(5003, 'q-9', 2001)),
                 'identical callback bytes keep one digest'
    refute_equal wire.fetch('raw_payload_hash'), digest_of(callback_update(5003, 'q-9', 2001, data: 'approve:abc')),
                 'a callback data change must change the digest'
  end

  def test_callback_observes_the_originating_message_date
    callback = callback_update(5008, 'q-11', 2003, date: 1_752_700_812)

    observed = normalizer.normalize(callback).wire.fetch('observed_time')

    assert_equal Time.at(1_752_700_812).utc.iso8601(6), observed
  end

  def test_callback_without_a_source_date_uses_ingestion_time
    callback = callback_update(5009, 'q-12', 2004)
    before = Time.now.utc
    observed = Time.parse(normalizer.normalize(callback).wire.fetch('observed_time'))
    after = Time.now.utc

    assert_operator observed, :>=, before
    assert_operator observed, :<=, after
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

    ids = wire.values_at('update_id', 'message_id', 'reply_to')

    assert_equal [5006, 46, 45], ids
    assert_nil wire.fetch('callback_message_id')
    assert_equal [5006, 46, 45], ids.uniq, 'the three ids must be distinct values on this fixture'
  end

  def test_a_callback_carries_its_update_id_beside_the_originating_message_id
    callback = normalizer.normalize(callback_update(5007, 'q-10', 2002)).wire

    assert_equal [5007, 2002], [callback.fetch('update_id'), callback.fetch('callback_message_id')]
  end

  def test_a_text_update_digest_is_unchanged_from_parser_version_one
    update = message_update(update_id: 5001, message_id: 42, reply_to: 7)

    assert_equal '41fa3431c144f74f319a3024fb14acbceaf9c8ffa1eb1759dd7281eada999f7b',
                 normalizer.normalize(update).wire.fetch('raw_payload_hash')
  end

  def attachment_update(fields = {}, caption: nil, **inline)
    message = message_update(update_id: 6001, message_id: 60).fetch('message').except('text')
                                                             .merge(fields, inline)
    message['caption'] = caption if caption
    { 'update_id' => 6001, 'message' => message }
  end

  def test_a_document_becomes_an_attachment_whose_caption_is_the_text
    wire = normalizer.normalize(attachment_update(
                                  { 'document' => { 'file_id' => 'D1', 'file_unique_id' => 'u-d1',
                                                    'file_name' => 'report.pdf', 'mime_type' => 'application/pdf',
                                                    'file_size' => 2048 } }, caption: 'summarize this'
                                )).wire

    assert_equal ['attachment', 'summarize this', 2], wire.values_at('kind', 'text', 'parser_version')
    assert_equal({ 'kind' => 'document', 'file_id' => 'D1', 'file_unique_id' => 'u-d1',
                   'media_type' => 'application/pdf', 'name' => 'report.pdf', 'size_bytes' => 2048,
                   'duration_s' => nil }, wire.fetch('attachment'))
  end

  def test_a_photo_picks_its_largest_size_and_an_image_document_is_an_image
    photo = normalizer.normalize(attachment_update(
                                   'photo' => [{ 'file_id' => 'small', 'file_unique_id' => 'u-s', 'width' => 90,
                                                 'height' => 60, 'file_size' => 900 },
                                               { 'file_id' => 'big', 'file_unique_id' => 'u-b', 'width' => 1280,
                                                 'height' => 960, 'file_size' => 90_000 }]
                                 )).wire.fetch('attachment')
    image_file = normalizer.normalize(attachment_update(
                                        'document' => { 'file_id' => 'P', 'file_unique_id' => 'u-p',
                                                        'mime_type' => 'image/png' }
                                      )).wire.fetch('attachment')

    assert_equal %w[image big image/jpeg], photo.values_at('kind', 'file_id', 'media_type')
    assert_equal %w[image P], image_file.values_at('kind', 'file_id')
  end

  def test_voice_and_audio_are_voice_attachments_with_a_duration
    voice = attachment_of('voice' => { 'file_id' => 'V', 'file_unique_id' => 'u-v', 'duration' => 12,
                                       'mime_type' => 'audio/ogg' })
    audio = attachment_of('audio' => { 'file_id' => 'A', 'file_unique_id' => 'u-a', 'duration' => 200,
                                       'file_name' => 'memo.mp3', 'mime_type' => 'audio/mpeg' })

    forwarded = attachment_of('voice' => { 'file_id' => 'F', 'file_unique_id' => 'u-f', 'duration' => 9 },
                              'forward_origin' => { 'type' => 'user', 'date' => 1 })

    assert_equal ['voice', 12, 'audio/ogg'], voice.values_at('kind', 'duration_s', 'media_type')
    assert_equal ['audio', 200, 'memo.mp3'], audio.values_at('kind', 'duration_s', 'name'),
                 'an audio file is someone else\'s speech'
    assert_equal 'audio', forwarded.fetch('kind'), 'a forwarded voice note is not the user\'s own words'
  end

  def test_a_sticker_video_or_animation_stays_unsupported_from_its_real_sender
    file = { 'file_id' => 'X', 'file_unique_id' => 'u-x' }
    [{ 'sticker' => file }, { 'video' => file }, { 'video_note' => file },
     { 'animation' => file, 'document' => file.merge('mime_type' => 'video/mp4') }].each do |fields|
      wire = normalizer.normalize(attachment_update(fields)).wire

      assert_equal 'unsupported', wire.fetch('kind'), fields.keys.inspect
      assert_equal 'telegram:user:11111111', wire.fetch('correspondent_id')
    end
  end

  def test_a_long_file_name_is_cut_never_refused
    name = "#{'ملف' * 50}.pdf"
    wire = normalizer.normalize(attachment_update('document' => { 'file_id' => 'D', 'file_unique_id' => 'u',
                                                                  'file_name' => name, 'mime_type' => 'x' * 300 })).wire
    attachment = wire.fetch('attachment')

    cut = attachment.fetch('name')

    assert_equal [true, true, 255], [cut.bytesize <= 255, cut.valid_encoding?, attachment.fetch('media_type').bytesize]
    assert_equal wire, Tamoz::Comms::InboundEnvelope.from_wire(wire).wire
  end

  def test_the_attachment_identity_and_caption_are_in_the_digest
    document = lambda { |unique, caption|
      attachment_update({ 'document' => { 'file_id' => 'D', 'file_unique_id' => unique } }, caption:)
    }
    base = normalizer.normalize(document.call('u-1', 'a')).wire.fetch('raw_payload_hash')

    refute_equal base, normalizer.normalize(document.call('u-2', 'a')).wire.fetch('raw_payload_hash')
    refute_equal base, normalizer.normalize(document.call('u-1', 'b')).wire.fetch('raw_payload_hash')
  end
end
