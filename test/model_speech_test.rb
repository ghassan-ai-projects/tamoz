# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'

class ModelSpeechTest < Minitest::Test
  MP3 = "ID3\x04\x00\x00\x00\x00\x00\x00\xFF\xFBspeech".b

  def with_endpoint(status: '200 OK', type: 'audio/mpeg', body: MP3)
    server = TCPServer.new('127.0.0.1', 0)
    seen = Queue.new
    thread = Thread.new do
      socket = server.accept
      head = +''
      head << socket.gets until head.end_with?("\r\n\r\n")
      seen << [head, socket.read(head[/content-length: (\d+)/i, 1].to_i)]
      socket.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n".b + body.b)
      socket.close
    rescue IOError, SystemCallError
      nil
    end
    yield Tamoz::Agent::EpisodeModelTransport.new(endpoint: "http://127.0.0.1:#{server.addr[1]}/v1",
                                                  model: 'hexgrad/kokoro-82m', provider: 'openrouter',
                                                  api_key: 'tts-key'), seen
  ensure
    thread&.join(2)
    server&.close
  end

  def test_the_text_and_voice_go_in_one_json_request_and_mp3_comes_back
    with_endpoint do |transport, seen|
      speech = transport.speak(text: 'Pond 7 is fine.', voice: 'af_heart')
      head, body = seen.pop

      assert_equal MP3, speech.audio
      assert_match(%r{\APOST /v1/audio/speech }, head)
      assert_match(/authorization: Bearer tts-key/i, head)
      assert_equal({ 'model' => 'hexgrad/kokoro-82m', 'input' => 'Pond 7 is fine.', 'voice' => 'af_heart',
                     'response_format' => 'mp3' }, JSON.parse(body))
      assert_equal transport.speech_digest('Pond 7 is fine.', 'af_heart'), speech.request_digest
    end
  end

  def test_a_refusal_is_a_typed_model_error
    with_endpoint(status: '402 Payment Required', type: 'application/json', body: '{"error":"no credit"}') do |t, _|
      error = assert_raises(Tamoz::Agent::ModelCallError) { t.speak(text: 'x', voice: 'v') }

      assert_equal ['http_failure', 402], [error.code, error.status]
    end
  end

  def test_a_body_that_is_not_mp3_is_refused
    with_endpoint(type: 'audio/mpeg', body: '{"error":"oops"}') do |transport, _seen|
      error = assert_raises(Tamoz::Agent::ModelCallError) { transport.speak(text: 'x', voice: 'v') }

      assert_equal 'invalid_response', error.code
    end
  end

  def test_a_body_past_the_bound_is_refused_not_truncated
    big = MP3 + ("\x00".b * (Tamoz::Agent::EpisodeModelTransport::MAX_SPEECH_BYTES + 1))
    with_endpoint(body: big) do |transport, _seen|
      error = assert_raises(Tamoz::Agent::ModelCallError) { transport.speak(text: 'x', voice: 'v') }

      assert_equal 'response_too_large', error.code
    end
  end

  def test_mp3_bytes_under_another_content_type_are_refused
    with_endpoint(type: 'text/html', body: MP3) do |transport, _seen|
      error = assert_raises(Tamoz::Agent::ModelCallError) { transport.speak(text: 'x', voice: 'v') }

      assert_equal 'invalid_response', error.code
    end
  end

  def test_an_unreachable_endpoint_is_an_unknown_outcome_and_a_blank_voice_is_refused
    port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
    transport = Tamoz::Agent::EpisodeModelTransport.new(endpoint: "http://127.0.0.1:#{port}/v1", model: 'm',
                                                        provider: 'openrouter')

    assert_raises(Tamoz::EffectUnknownError) { transport.speak(text: 'x', voice: 'v') }
    assert_raises(Tamoz::ConfigurationError) { transport.speak(text: 'x', voice: '') }
  end

  def test_the_digest_binds_model_voice_and_text
    one = Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'http://x/v1', model: 'm1', provider: 'openrouter')
    two = Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'http://x/v1', model: 'm2', provider: 'openrouter')

    refute_equal one.speech_digest('a', 'v1'), one.speech_digest('a', 'v2')
    refute_equal one.speech_digest('a', 'v1'), one.speech_digest('b', 'v1')
    refute_equal one.speech_digest('a', 'v1'), two.speech_digest('a', 'v1')
  end
end
