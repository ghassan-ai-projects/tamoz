# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fake_provider'
require_relative 'support/talk_chat_eval'
require_relative 'support/talk_fixtures'

# The real `tamoz talk setup|start`, gateway and worker processes against a fake provider: plumbing, not
# intelligence.
# rubocop:disable Minitest/MultipleAssertions
class TalkEndToEndTest < Minitest::Test
  include TalkFixtures

  def test_a_spoken_question_is_heard_answered_and_spoken_and_text_status_and_stop_work
    working = Queue.new
    provider = TalkFakeProvider.new(answer: lambda { |text|
      (working << true) && sleep(30) if text.include?('take your time')
      'Pond 7 is fine.'
    }).start
    env = { 'PATH' => ENV.fetch('PATH'), 'HOME' => Dir.home,
            'ZAI_API_KEY' => 'chat-key', 'ZAI_API_BASE' => provider.base_url,
            'TAMOZ_TRANSCRIPTION_PROVIDER' => 'openai', 'TAMOZ_TRANSCRIPTION_MODEL' => 'whisper-1',
            'TAMOZ_TRANSCRIPTION_API_BASE' => provider.base_url, 'TAMOZ_TRANSCRIPTION_CREDENTIAL' => 'SPEECH_KEY',
            'TAMOZ_VOICE_PROVIDER' => 'openai', 'TAMOZ_VOICE_MODEL' => 'tts-1', 'TAMOZ_VOICE_NAME' => 'alloy',
            'TAMOZ_VOICE_API_BASE' => provider.base_url, 'TAMOZ_VOICE_CREDENTIAL' => 'SPEECH_KEY',
            'SPEECH_KEY' => 'speech-key', 'TAMOZ_PROVIDER' => 'zai', 'TAMOZ_MODEL' => 'glm-5.3-flash' }
    eval = TalkChatEval.new(env:).start
    started = eval.now

    assert_equal 200, eval.say_audio(wav(1.5))
    heard = eval.await(since: started) { |event| event['text'].to_s.start_with?('Heard:') }
    answer = eval.await(since: started) { |event| event['kind'] == 'answer' }

    assert_equal 'Heard: «check pond seven»', heard.data['text']
    assert_equal 'Pond 7 is fine.', answer.data['text']
    assert answer.data['spoken']
    assert_equal [200, TalkFakeProvider::MP3], eval.speech(answer.data['message_id'])
    typed = eval.now

    assert_equal 200, eval.say_text('and pond 8?')
    eval.await(since: typed) { |event| event['kind'] == 'answer' }
    asked = eval.now

    assert_equal 200, eval.say_text('/status')
    eval.await(since: asked) { |event| event['kind'] == 'control' && !event['text'].start_with?('Heard:') }
    slow = eval.now

    assert_equal 200, eval.say_text('take your time with pond 9')
    assert working.pop(timeout: 60), 'the slow request reached the model'

    assert_equal 200, eval.say_text('/cancel')
    stopped = eval.await(since: slow) { |event| event['kind'] == 'stopped' }

    assert_equal 'Stopped.', stopped.data['text']
    refute(eval.messages(since: slow).any? { |event| event.data['kind'] == 'answer' }, 'the stopped turn never answers')
  ensure
    eval&.stop
    provider&.stop
  end
end
# rubocop:enable Minitest/MultipleAssertions
