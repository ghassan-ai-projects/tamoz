# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'

class ModelTranscriptionTest < Minitest::Test
  AUDIO = "OggS\x00\x02voice-bytes\xFF".b

  def with_endpoint(status: '200 OK', body: '{"text":"my locker code is four seven one nine"}')
    server = TCPServer.new('127.0.0.1', 0)
    seen = Queue.new
    thread = Thread.new do
      socket = server.accept
      head = +''
      head << socket.gets until head.end_with?("\r\n\r\n")
      length = head[/content-length: (\d+)/i, 1].to_i
      seen << [head, socket.read(length)]
      socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
      socket.close
    end
    yield Tamoz::Agent::EpisodeModelTransport.new(endpoint: "http://127.0.0.1:#{server.addr[1]}/v1", model: 'whisper-1',
                                                  provider: 'openai', api_key: 'stt-key'), seen
  ensure
    thread&.join(2)
    server&.close
  end

  def test_the_audio_goes_as_received_in_one_multipart_request
    with_endpoint do |transport, seen|
      transcript = transport.transcribe(audio: AUDIO, filename: 'voice.ogg', media_type: 'audio/ogg')
      head, body = seen.pop

      assert_equal 'my locker code is four seven one nine', transcript.text
      assert_match(%r{\APOST /v1/audio/transcriptions }, head)
      assert_match(/authorization: Bearer stt-key/i, head)
      assert_includes body.b, "name=\"model\"\r\n\r\nwhisper-1".b
      assert_includes body.b, "filename=\"voice.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n#{AUDIO}".b
      assert_equal transport.transcription_digest(Digest::SHA256.hexdigest(AUDIO)), transcript.request_digest
    end
  end

  def test_a_refused_call_is_a_typed_model_error
    with_endpoint(status: '402 Payment Required', body: '{"error":"no credit"}') do |transport, _seen|
      error = assert_raises(Tamoz::Agent::ModelCallError) do
        transport.transcribe(audio: AUDIO, filename: 'voice.ogg', media_type: 'audio/ogg')
      end
      assert_equal 'http_failure', error.code
    end
  end

  def test_an_answer_without_text_is_invalid
    with_endpoint(body: '{"segments":[]}') do |transport, _seen|
      error = assert_raises(Tamoz::Agent::ModelCallError) do
        transport.transcribe(audio: AUDIO, filename: 'voice.ogg', media_type: 'audio/ogg')
      end
      assert_equal 'invalid_response', error.code
    end
  end

  def test_the_same_audio_is_the_same_request_identity
    transport = Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'http://x/v1', model: 'whisper-1', provider: 'openai')

    assert_equal transport.transcription_digest('a' * 64), transport.transcription_digest('a' * 64)
    refute_equal transport.transcription_digest('a' * 64), transport.transcription_digest('b' * 64)
  end
end
