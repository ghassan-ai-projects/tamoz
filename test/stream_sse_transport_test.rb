# frozen_string_literal: true

require 'net/http'

require_relative 'test_helper'
require 'tamoz/stream/sse_transport'

class StreamSseTransportTest < Minitest::Test
  class FakeSuccess < Net::HTTPOK
    def initialize(chunks, code: '200', message: 'OK')
      super('1.1', code, message)
      @chunks = chunks
    end

    def read_body(&)
      @chunks.each(&)
    end
  end

  class FakeFailure < Net::HTTPResponse
    def initialize(chunks, code:, message:)
      super('1.1', code, message)
      @chunks = chunks
    end

    def read_body(&)
      @chunks.each(&)
    end
  end

  class FakeHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      yield response
    end
  end

  def test_parses_sse_and_sends_bearer_and_last_event_id
    event = cloud_event('evt-1', 'io.agenticstream.outcome.reconciled.v1')
    http = FakeHttp.new([
      FakeSuccess.new([
        ": heartbeat\n\n",
        "id: 42\nevent: io.agenticstream.outcome.reconciled.v1\n",
        "data: #{event}\n\n"
      ])
    ])
    transport = transport_for(http)

    frames = transport.open(cursor: '41', credential: 'secret').to_a

    assert_event_frame(frames.fetch(0), event)
    assert_request_headers(http.requests.fetch(0))
  end

  def test_reconnects_retryable_http_failures_with_backoff_and_cursor_resume
    event = cloud_event('evt-2', 'io.agenticstream.test.v1')
    http = FakeHttp.new([
      FakeFailure.new([], code: '503', message: 'Service Unavailable'),
      FakeSuccess.new(["id: 43\ndata: #{event}\n\n"])
    ])
    transport = transport_for(http, reconnect_delay: 0.001)

    frames = transport.open(cursor: '41', credential: 'secret').to_a

    assert_equal ['43'], frames.map(&:cursor)
    assert_equal 2, http.requests.length
    assert(http.requests.all? { |request| request['Last-Event-ID'] == '41' })
  end

  def test_parses_control_events
    http = FakeHttp.new([
      FakeSuccess.new(["id: 44\nevent: cursor_expired\ndata: {}\n\n"])
    ])
    transport = transport_for(http)

    frame = transport.open(cursor: '41', credential: 'secret').to_a.fetch(0)

    assert_equal :control, frame.type
    assert_equal 'cursor_expired', frame.control
    assert_equal '44', frame.cursor
  end

  private

  def cloud_event(id, type)
    JSON.generate(
      'id' => id,
      'source' => 'stream-1',
      'type' => type,
      'data' => { 'intent_id' => 'intent-1' }
    )
  end

  def assert_event_frame(frame, data)
    assert_equal(
      { type: :event, cursor: '42', event: 'io.agenticstream.outcome.reconciled.v1', data:, control: nil },
      frame.to_h
    )
  end

  def assert_request_headers(request)
    assert_equal(
      { authorization: 'Bearer secret', last_event_id: '41', path: '/v1/events' },
      {
        authorization: request['Authorization'],
        last_event_id: request['Last-Event-ID'],
        path: request.path
      }
    )
  end

  def transport_for(http, reconnect_delay: 0)
    Tamoz::Stream::SseTransport.new(
      endpoint: 'http://stream.test/v1/events',
      reconnect_delay:,
      reconnect_on_eof: false,
      http_factory: ->(_uri) { http }
    )
  end
end
