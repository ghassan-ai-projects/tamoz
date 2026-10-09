# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fixtures'
require 'json'

# rubocop:disable Minitest/MultipleAssertions
class TalkServerTest < Minitest::Test
  include TalkFixtures

  def teardown = stop_hubs

  API = [%w[POST /v1/messages], %w[POST /v1/utterances?update_id=1], %w[POST /v1/decisions], %w[GET /v1/events],
         %w[GET /v1/speech/1], %w[GET /v1/trace]].freeze

  def test_every_api_route_refuses_a_missing_or_wrong_token_without_reading_the_body
    hub = start_hub
    API.each do |method, path|
      [nil, 'wrong', "#{TOKEN}x"].each do |token|
        socket = raw(hub, "#{method} #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{hub.port}\r\nContent-Length: 999999\r\n" \
                          "#{"Authorization: Bearer #{token}\r\n" if token}\r\n", read: false)
        response = parse(socket.read)
        socket.close

        assert_equal 401, response.status, "#{method} #{path} #{token.inspect}"
        assert_equal '', response.body
        assert_equal 'no-store', response.headers['cache-control']
      end
    end
  end

  def test_a_foreign_host_is_refused_and_an_allowed_name_is_served
    hub = start_hub

    assert_equal 421, http(hub, 'GET', '/v1/events?timeout=0', host: 'evil.test').status
    assert_equal 421, http(hub, 'GET', '/v1/events?timeout=0', host: "127.0.0.1:#{hub.port + 1}").status
    assert_equal 200, http(hub, 'GET', '/v1/events?timeout=0', host: 'mac.tail.ts.net').status
    assert_equal 200, http(hub, 'GET', '/v1/events?timeout=0', host: "localhost:#{hub.port}").status
  end

  def test_a_preflight_gets_no_cors_headers
    hub = start_hub
    response = http(hub, 'OPTIONS', '/v1/messages', token: nil,
                                                    headers: { 'Origin' => 'https://evil.test',
                                                               'Access-Control-Request-Headers' => 'authorization' })

    refute_equal 200, response.status
    assert(response.headers.keys.none? { |name| name.start_with?('access-control') })
  end

  def test_a_message_is_admitted_once_the_gateway_confirms_it
    hub = start_hub(submit_timeout_s: 5)
    client = Thread.new { http(hub, 'POST', '/v1/messages', body: JSON.generate('update_id' => 7, 'text' => 'hello')) }
    eventually { hub.inbox.size == 1 }
    updates = confirm_all(hub)
    response = client.value

    assert_equal [200, { 'admitted' => true }], [response.status, JSON.parse(response.body)]
    assert_equal([%w[text hello talk:user:1 talk:chat:1]],
                 updates.map { |wire| wire.values_at('kind', 'text', 'correspondent_id', 'conversation_id') })
  end

  def test_an_unconfirmed_message_is_503_so_the_page_resends_the_same_id
    hub = start_hub(submit_timeout_s: 0.05)
    response = http(hub, 'POST', '/v1/messages', body: JSON.generate('update_id' => 7, 'text' => '/status'))

    assert_equal 503, response.status
    assert_equal 'command', hub.inbox.poll(next_offset: nil, limit: 5, timeout_s: 0)[:updates].first['kind']
  end

  def test_malformed_and_oversized_requests_are_typed_refusals
    hub = start_hub

    assert_equal 400, http(hub, 'POST', '/v1/messages', body: 'not json').status
    assert_equal 400, http(hub, 'POST', '/v1/messages', body: JSON.generate('update_id' => 2**53, 'text' => 'x')).status
    assert_equal 400, http(hub, 'POST', '/v1/messages', body: JSON.generate('update_id' => 1, 'text' => ' ')).status
    assert_equal 413, http(hub, 'POST', '/v1/messages', body: 'x' * 9000).status
    assert_equal 400, http(hub, 'POST', '/v1/decisions',
                           body: JSON.generate('update_id' => 1, 'action' => 'maybe', 'reference' => 'r',
                                               'message_id' => 1)).status
    assert_equal 405, http(hub, 'GET', '/v1/messages').status
    assert_equal 404, http(hub, 'GET', '/v1/nothing').status
    assert_equal 404, http(hub, 'GET', '/v1/trace').status, 'the trace route exists only when asked for'
  end

  def test_an_utterance_must_be_a_short_16k_mono_wav
    hub = start_hub
    audio = { 'Content-Type' => 'audio/wav' }

    assert_equal 415, http(hub, 'POST', '/v1/utterances?update_id=3', body: 'RIFF', headers: audio).status
    assert_equal 415, http(hub, 'POST', '/v1/utterances?update_id=3', body: wav(1, rate: 44_100), headers: audio).status
    assert_equal 415,
                 http(hub, 'POST', '/v1/utterances?update_id=3', body: wav(1),
                                                                 headers: { 'Content-Type' => 'text/plain' }).status
    assert_equal 413, http(hub, 'POST', '/v1/utterances?update_id=3', body: wav(61), headers: audio).status
    assert_equal 503, http(hub, 'POST', '/v1/utterances?update_id=3', body: wav(1), headers: audio).status
    held = hub.inbox.poll(next_offset: nil, limit: 5, timeout_s: 0)[:updates].first

    assert_equal %w[voice audio/wav talk-3], held['attachment'].values_at('kind', 'media_type', 'file_id')
    assert_equal wav(1), hub.inbox.audio('talk-3')
  end

  def test_events_and_speech_routes
    hub = start_hub(synthesize: ->(_text) { "ID3\x04".b })
    receipt = hub.deliver(Tamoz::Comms::Delivery.build(conversation_id: 'talk:chat:1', kind: 'answer', text: 'Fine.',
                                                       render_version: 1, content_digest: 'a' * 64))
    events = JSON.parse(http(hub, 'GET', '/v1/events?after=0&timeout=0&speech=1').body)
    speech = http(hub, 'GET', "/v1/speech/#{receipt.fetch('message_id')}")

    assert_equal(['Fine.'], events['events'].map { |event| event['text'] })
    assert events['reset'], 'a page with no epoch starts from the whole log'
    assert_equal [200, 'audio/mpeg', "ID3\x04".b], [speech.status, speech.headers['content-type'], speech.body]
    assert_equal 404, http(hub, 'GET', '/v1/speech/42').status
  end

  def test_duplicate_identity_headers_and_odd_request_lines_are_refused
    hub = start_hub
    base = "GET /v1/events?timeout=0 HTTP/1.1\r\n"
    auth = "Authorization: Bearer #{TOKEN}\r\n"

    assert_equal 400, raw(hub, "#{base}Host: evil.test\r\nHost: 127.0.0.1:#{hub.port}\r\n#{auth}\r\n").status
    assert_equal 400, raw(hub, "#{base}Host: 127.0.0.1:#{hub.port}\r\n#{auth}Authorization: Bearer x\r\n\r\n").status
    assert_equal 400, raw(hub, "GET  /v1/events HTTP/1.1\r\nHost: 127.0.0.1:#{hub.port}\r\n\r\n").status
    assert_equal 400, raw(hub, "GET / HTTP/1.1 extra\r\nHost: 127.0.0.1:#{hub.port}\r\n\r\n").status
    assert_equal 200, http(hub, 'GET', '/v1/events?timeout=0', host: "[::1]:#{hub.port}").status
    assert_equal 200, http(hub, 'GET', '/v1/events?timeout=0', host: "LOCALHOST:#{hub.port}").status
    assert_equal 421, http(hub, 'GET', '/v1/events?timeout=0', host: "localhost.:#{hub.port}").status
  end

  def test_invalid_text_and_references_are_refused
    hub = start_hub

    assert_equal 400, http(hub, 'POST', '/v1/messages', body: %({"update_id":1,"text":"\xFF"}).b).status
    assert_equal 400, http(hub, 'POST', '/v1/decisions',
                           body: JSON.generate('update_id' => 1, 'action' => 'approve', 'reference' => "a\u0000b",
                                               'message_id' => 1)).status
  end

  def test_the_accept_loop_survives_a_failed_accept
    hub = start_hub
    listener = hub.instance_variable_get(:@server).instance_variable_get(:@listener)
    failures = [Errno::ECONNABORTED.new]
    listener.singleton_class.define_method(:accept) { failures.empty? ? super() : raise(failures.shift) }
    capture_subprocess_io { http(hub, 'GET', '/v1/events?timeout=0') }

    assert_equal 200, http(hub, 'GET', '/v1/events?timeout=0').status
    assert_predicate hub, :alive?
  end

  def test_the_token_is_never_logged
    hub = start_hub
    hub.log.define_singleton_method(:since) { |**| raise "boom #{TOKEN}" }
    _out, err = capture_subprocess_io { http(hub, 'GET', '/v1/events?timeout=0') }

    refute_includes err, TOKEN
    assert_includes err, 'RuntimeError'
  end
end
# rubocop:enable Minitest/MultipleAssertions
