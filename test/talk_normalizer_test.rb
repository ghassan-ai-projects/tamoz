# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fixtures'

# rubocop:disable Minitest/MultipleAssertions
class TalkNormalizerTest < Minitest::Test
  include TalkFixtures

  def normalizer = Tamoz::Talk::Normalizer.new(surface_id: 'talk', surface_revision: 1)

  def utterance(update_id, seconds)
    normalizer.utterance(update_id:, audio: wav(seconds), duration_s: seconds.to_f)
  end

  def sample_envelopes
    [normalizer.text(update_id: 1, text: 'hello'), normalizer.text(update_id: 2, text: '/status'),
     normalizer.decision(update_id: 3, action: 'approve', reference: 'abc', message_id: 99), utterance(4, 2)]
  end

  def test_text_commands_decisions_and_voice_become_envelopes
    text, command, decision, voice = sample_envelopes

    assert_equal(%w[text command callback attachment], [text, command, decision, voice].map { |wire| wire['kind'] })
    assert_equal ['approve:abc', 99, '3'], decision.values_at('text', 'callback_message_id', 'callback_query_id')
    assert_equal ['voice', 'talk-4', 2, wav(2).bytesize], voice['attachment'].values_at('kind', 'file_id', 'duration_s',
                                                                                        'size_bytes')
    assert_nil voice['text']
  end

  def test_the_digest_changes_with_the_audio_and_the_update_id_only
    one, again, other_audio, other_id = [[4, 1], [4, 1], [4, 2], [5, 1]].map do |update_id, seconds|
      utterance(update_id, seconds)['raw_payload_hash']
    end

    assert_equal one, again, 'a resend is a duplicate'
    refute_equal one, other_audio
    refute_equal one, other_id, 'two identical utterances never share a spool file'
  end

  def test_an_update_id_must_fit_a_browser_number
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: 2**53, text: 'x') }
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: 0, text: 'x') }
    assert_raises(Tamoz::Comms::ValidationError) { normalizer.text(update_id: '7', text: 'x') }
  end
end
# rubocop:enable Minitest/MultipleAssertions
