# frozen_string_literal: true

require 'json'
require 'socket'

# An in-memory Telegram Bot API fixture (design §6.4 conformance): scripted
# JSON responses per method, able to duplicate/reorder updates, throttle with
# the authoritative retry_after, lose a poll response, and delay beyond the
# client timeout. Each request is served on a worker thread so a slow response
# does not block the next call.
class TelegramFixtureServer
  attr_reader :port, :requests

  def initialize(token: 'test-token')
    @token = token
    @script = {}
    @requests = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @running = true
    @threads = []
    @lock = Mutex.new
    @worker = Thread.new { accept_loop }
  end

  def url = "http://127.0.0.1:#{@port}"

  # @param method [String] e.g. 'getMe'
  # @param status [Integer] HTTP status
  # @param body [Hash] the JSON body
  # @param times [Integer] how many requests this script answers; 0 = always
  # @param delay_s [Float] sleep before responding (for timeout tests)
  def script(method, status: 200, body: nil, times: 0, delay_s: 0.0)
    @lock.synchronize do
      (@script[method] ||= []) << { status:, body:, remaining: times, delay_s: }
    end
  end

  def stop
    @running = false
    begin
      @server.close
    rescue StandardError
      nil
    end
    @worker.join(2)
    @threads.each { |thread| thread.join(2) }
  end

  private

  def accept_loop
    while @running
      socket = @server.accept
      @threads << Thread.new(socket) { |client| serve(client) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    request_line = socket.gets
    return socket.close unless request_line

    method = request_line.split[1].split('/').last
    body = consume_headers_and_body(socket)
    @lock.synchronize { @requests << { method:, body: } }
    response = response_for(method)
    sleep response[:delay_s] if response[:delay_s].positive?
    socket.write http_response(response)
    socket.close
  end

  def consume_headers_and_body(socket)
    content_length = 0
    loop do
      line = socket.gets
      break if line.nil? || line == "\r\n"

      content_length = line.split(':').last.to_i if line.start_with?('Content-Length:')
    end
    return nil if content_length.zero?

    socket.read(content_length)
  end

  def response_for(method)
    @lock.synchronize do
      queue = @script[method]
      return { status: 200, body: nil, delay_s: 0.0 } unless queue && !queue.empty?

      entry = queue.first
      if entry[:remaining].positive?
        entry[:remaining] -= 1
        queue.shift if entry[:remaining].zero?
      end
      entry
    end
  end

  def http_response(entry)
    body = entry[:body] ? JSON.generate(entry[:body]) : '{}'
    status = entry[:status]
    reason = { 200 => 'OK', 401 => 'Unauthorized', 429 => 'Too Many Requests' }.fetch(status, 'OK')
    headers = "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
    "HTTP/1.1 #{status} #{reason}\r\n#{headers}#{body}"
  end
end
