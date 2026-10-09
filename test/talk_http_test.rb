# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fixtures'
require 'io/wait'

class TalkHttpTest < Minitest::Test
  include TalkFixtures

  def teardown = stop_hubs

  def head(hub, extra = '', line: 'GET /v1/events?timeout=0 HTTP/1.1')
    "#{line}\r\nHost: 127.0.0.1:#{hub.port}\r\nAuthorization: Bearer #{TOKEN}\r\n#{extra}"
  end

  def test_a_dripped_request_hits_its_deadline_and_cannot_extend_it
    hub = start_hub(deadlines: { head: 0.15, body: 0.15 })
    socket = raw(hub, 'GET /v1/events', read: false)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    15.times do
      break if socket.wait_readable(0.1)

      socket.write('x')
    rescue IOError, SystemCallError
      break
    end
    response = parse(socket.read)

    assert_equal 408, response.status
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
  ensure
    socket&.close
  end

  def test_malformed_heads_are_refused_before_any_body_is_read
    hub = start_hub
    cases = {
      'bare LF' => "GET /v1/events HTTP/1.1\nHost: 127.0.0.1:#{hub.port}\r\n\r\n",
      'folded header' => "#{head(hub, " continued\r\n")}\r\n",
      'transfer-encoding' => "#{head(hub, "Transfer-Encoding: chunked\r\n")}\r\n",
      'duplicate length' => "#{head(hub, "Content-Length: 1\r\nContent-Length: 1\r\n")}\r\n",
      'non-digit length' => "#{head(hub, "Content-Length: 1e3\r\n")}\r\n",
      'not HTTP/1.1' => "#{head(hub, '', line: 'GET /v1/events HTTP/1.0')}\r\n",
      'relative target' => "#{head(hub, '', line: 'GET v1/events HTTP/1.1')}\r\n",
      'bad header name' => "#{head(hub, "Bad Name: x\r\n")}\r\n"
    }

    cases.each { |name, bytes| assert_equal 400, raw(hub, bytes).status, name }
  end

  def test_too_many_or_too_large_headers_are_refused
    hub = start_hub
    many = (1..65).map { |index| "X-#{index}: v\r\n" }.join

    assert_equal 431, raw(hub, "#{head(hub, many)}\r\n").status
    assert_equal 431, raw(hub, "#{head(hub, "X-Big: #{'a' * 17_000}\r\n")}\r\n").status
    assert_equal 400, raw(hub, "GET /#{'a' * 2100} HTTP/1.1\r\nHost: x\r\n\r\n").status
  end

  def test_an_oversized_body_is_refused_from_its_declared_length
    hub = start_hub
    socket = raw(hub, "#{head(hub, "Content-Length: 50000000\r\n", line: 'POST /v1/messages HTTP/1.1')}\r\n",
                 read: false)

    assert_equal 413, parse(socket.read).status
  ensure
    socket&.close
  end

  def test_a_dripped_body_hits_its_deadline
    hub = start_hub(deadlines: { head: 0.15, body: 0.15 })
    line = 'POST /v1/messages HTTP/1.1'
    socket = raw(hub, "#{head(hub, "Content-Length: 100\r\nContent-Type: application/json\r\n", line:)}\r\n{",
                 read: false)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    10.times do
      break if socket.wait_readable(0.1)

      socket.write(' ')
    rescue IOError, SystemCallError
      break
    end

    assert_equal 408, parse(socket.read).status
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
  ensure
    socket&.close
  end

  def test_a_refusal_after_an_unread_body_still_reaches_the_client
    hub = start_hub
    body = 'x' * 200_000
    response = raw(hub, "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:#{hub.port}\r\n" \
                        "Content-Length: #{body.bytesize}\r\n\r\n#{body}")

    assert_equal 401, response.status
  end

  def test_a_client_that_never_reads_cannot_hold_a_slot_past_the_write_deadline
    hub = start_hub(deadlines: { head: 0.5, body: 0.5, write: 0.1 })
    600.times { |index| hub.log.append_message('kind' => 'answer', 'text' => "#{'x' * 3000} #{index}") }
    readers = Array.new(Tamoz::Talk::Server::MAX_CONNECTIONS) do
      socket = Socket.new(:INET, :STREAM)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1024)
      socket.connect(Socket.sockaddr_in(hub.port, '127.0.0.1'))
      socket.write("GET /v1/events?timeout=0 HTTP/1.1\r\nHost: 127.0.0.1:#{hub.port}\r\n" \
                   "Authorization: Bearer #{TOKEN}\r\n\r\n")
      socket
    end

    eventually(3) do
      http(hub, 'GET', '/v1/events?timeout=0&after=0').status == 200
    rescue SystemCallError
      false
    end
  ensure
    Array(readers).each(&:close)
  end

  def test_the_connection_cap_holds
    hub = start_hub(deadlines: { head: 2, body: 2 })
    idle = Array.new(Tamoz::Talk::Server::MAX_CONNECTIONS) { raw(hub, 'G', read: false) }
    sleep 0.1
    extra = TCPSocket.new('127.0.0.1', hub.port)

    assert_equal 503, parse(extra.read).status
  ensure
    extra&.close
    Array(idle).each(&:close)
  end
end
