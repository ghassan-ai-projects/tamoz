# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fixtures'

# rubocop:disable Minitest/MultipleAssertions
class TalkNormalizerTest < Minitest::Test
  include TalkFixtures

  def normalizer = Tamoz::Talk::Normalizer.new(surface_id: 'talk', surface_revision: 1)

  def test_text_commands_decisions_and_voice_become_envelopes
    text = normalizer.text(update_id: 1, text: 'hello')
    command = normalizer.text(update_id: 2, text: '/status')
    decision = normalizer.decision(update_id: 3, action: 'approve', reference: 'abc', message_id: 99)
    voice = normalizer.utterance(update_id: 4, audio: wav(2), duration_s: 2.0)

    assert_equal(%w[text command callback attachment], [text, command, decision, voice].map { |wire| wire['kind'] })
    assert_equal ['approve:abc', 99, '3'], decision.values_at('text', 'callback_message_id', 'callback_query_id')
    assert_equal ['voice', 'talk-4', 2, wav(2).bytesize], voice['attachment'].values_at('kind', 'file_id', 'duration_s',
                                                                                        'size_bytes')
    assert_nil voice['text']
  end

  def test_the_digest_changes_with_the_audio_and_the_update_id_only
    one = normalizer.utterance(update_id: 4, audio: wav(1), duration_s: 1.0)
    again = normalizer.utterance(update_id: 4, audio: wav(1), duration_s: 1.0)
    other_audio = normalizer.utterance(update_id: 4, audio: wav(2), duration_s: 2.0)
    other_id = normalizer.utterance(update_id: 5, audio: wav(1), duration_s: 1.0)

    assert_equal one['raw_payload_hash'], again['raw_payload_hash'], 'a resend is a duplicate'
    refute_equal one['raw_payload_hash'], other_audio['raw_payload_hash']
    refute_equal one['raw_payload_hash'], other_id['raw_payload_hash'],
                 'two identical utterances never share a spool file'
  end

  def test_an_update_id_must_fit_a_browser_number
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: 2**53, text: 'x') }
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: 0, text: 'x') }
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: '7', text: 'x') }
  end
end
# rubocop:enable Minitest/MultipleAssertions
