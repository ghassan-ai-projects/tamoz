# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions
class CoreSpokenTextTest < Minitest::Test
  Spoken = Tamoz::Core::SpokenText

  def speak(text, kind: 'answer', more: false) = Spoken.project(text, kind:, more:)

  def test_only_spoken_kinds_are_spoken
    assert_nil speak('Heard: «check pond 7»', kind: 'control')
    assert_nil speak('anything', kind: 'notice')
    assert_equal Spoken::APPROVAL, speak("I want to edit `app.rb`:\n```diff\n-a\n+b\n```", kind: 'approval_request')
    assert_equal 'Stopped.', speak('Stopped.', kind: 'stopped')
    assert_equal 'Something went wrong.', speak('Something went wrong.', kind: 'failed')
  end

  def test_code_tables_links_and_marks_become_words
    text = "## Result\n**Pond 7** is fine. See [the log](https://x.test/log) or https://x.test/raw.\n" \
           "```ruby\nputs 1\n```\n```diff\n-a\n+b\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n- Aerator `on`."

    assert_equal 'Result Pond 7 is fine. See the log or a link The code is on screen. The table is on screen. ' \
                 'Aerator on.', speak(text)
  end

  def test_an_unclosed_fence_still_hides_the_code
    assert_equal 'Here: The code is on screen.', speak("Here:\n```\nsecret = 1\nmore")
  end

  def test_paths_digests_references_and_timestamps_are_not_read_out
    text = 'Changed `gems/tamoz-talk/lib/x.rb` and settings.yaml; see config/app.yml. Digest sha256:' \
           "#{'a' * 64} in r0123456789 at 2026-10-09T06:10:00Z."

    assert_equal 'Changed a file name and a file name; see a file name. Digest in at 06:10.', speak(text)
    assert_equal 'Use e.g. pond 6.1 as before.', speak('Use e.g. pond 6.1 as before.')
  end

  def test_a_long_answer_is_cut_at_a_sentence_and_says_the_rest_is_on_screen
    sentence = 'Pond seven oxygen fell from six point one to four point three since six this morning. '
    spoken = speak(sentence * 10)

    assert spoken.end_with?(Spoken::REST)
    assert_operator spoken.length, :<=, Spoken::MAX_CHARACTERS + Spoken::REST.length + 1
    assert spoken.delete_suffix(" #{Spoken::REST}").end_with?('.')
    assert_equal "Short. #{Spoken::REST}", speak('Short.', more: true)
  end

  def test_nothing_left_to_say_is_silence
    assert_nil speak('`abcdef0123456789`'.delete('`') * 1)
  end

  def test_an_echo_is_most_of_a_long_heard_passage_in_order_in_what_was_spoken
    spoken = 'Pond 7 oxygen fell from 6.1 to 4.3 since six this morning. Aerator 2 stopped at 6:10.'

    assert Spoken.echo?('pond 7 oxygen fell from 6.1 to 4.3 since six this morning', spoken)
    refute Spoken.echo?('yes pond 7 oxygen is 6.1', spoken), 'a short repeat-back is the user talking'
    refute Spoken.echo?('pond 7 oxygen fell from 6.1 to', spoken), 'seven words are never an echo'
    assert Spoken.echo?('pond 7 oxygen fell from 6.1 to 4.3 since six this nonsense', spoken), '11 of 12 words'
    refute Spoken.echo?('pond 7 oxygen fell nonsense nonsense from 6.1 to 4.3', spoken), '8 of 10 is under 85%'
    refute Spoken.echo?('morning this since 4.3 to 6.1 from fell oxygen 7 pond', spoken), 'out of order'
    refute Spoken.echo?('please check aerator three now and tell me why it stopped', spoken)
  end
end
# rubocop:enable Minitest/MultipleAssertions
