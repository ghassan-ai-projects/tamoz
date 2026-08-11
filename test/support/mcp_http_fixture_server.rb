# frozen_string_literal: true

require 'json'
require 'socket'

# A small Streamable HTTP MCP peer for integration tests. It speaks the same
# JSON-RPC requests as the real SDK client, including session and notification
# handling, so HTTP support is tested through the wire rather than a fake client.
class McpHttpFixtureServer
  attr_reader :port, :requests

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @requests = []
    @running = true
    @session_id = 'fixture-session'
    @lock = Mutex.new
    @threads = []
    @worker = Thread.new { accept_loop }
  end

  def url = "http://127.0.0.1:#{@port}/mcp"

  def stop
    @running = false
    @server.close
    @worker.join(2)
    @threads.each { |thread| thread.join(2) }
  rescue IOError, Errno::EBADF
    nil
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

    method, path, = request_line.split
    headers = read_headers(socket)
    body = headers.fetch('content-length', '0').to_i
    payload = body.positive? ? JSON.parse(socket.read(body)) : nil
    record_request(method, path, headers, payload)
    status, response_headers, response_body = response_for(method, payload)
    socket.write(http_response(status, response_headers, response_body))
  rescue JSON::ParserError
    socket.write(http_response(400, {}, { 'error' => 'invalid json' }))
  ensure
    socket.close unless socket.closed?
  end

  def read_headers(socket)
    headers = {}
    loop do
      line = socket.gets
      break if line.nil? || line == "\r\n"

      name, value = line.split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    headers
  end

  def record_request(method, path, headers, payload)
    @lock.synchronize { @requests << { method:, path:, headers:, payload: } }
  end

  # rubocop:disable Metrics/MethodLength
  def response_for(method, payload)
    return [200, {}, nil] if method == 'DELETE'
    return [405, {}, nil] unless method == 'POST'
    return [202, {}, nil] unless payload && payload['id']

    result = case payload.fetch('method')
             when 'initialize'
               {
                 'protocolVersion' => '2026-07-28',
                 'capabilities' => { 'tools' => {} },
                 'serverInfo' => { 'name' => 'fixture', 'version' => '1' }
               }
             when 'tools/list'
               { 'tools' => [{
                 'name' => 'finish',
                 'description' => 'Finish the task',
                 'inputSchema' => { 'type' => 'object', 'properties' => {}, 'additionalProperties' => false }
               }] }
             when 'tools/call'
               { 'content' => [{ 'type' => 'text', 'text' => 'done' }] }
             else
               {}
             end

    [200, { 'Mcp-Session-Id' => @session_id }, { 'jsonrpc' => '2.0', 'id' => payload['id'], 'result' => result }]
  end
  # rubocop:enable Metrics/MethodLength

  def http_response(status, headers, body)
    content = body.nil? ? '' : JSON.generate(body)
    reason = { 200 => 'OK', 202 => 'Accepted', 400 => 'Bad Request', 405 => 'Method Not Allowed' }.fetch(status)
    default_headers = {
      'Content-Type' => 'application/json',
      'Content-Length' => content.bytesize,
      'Connection' => 'close'
    }
    all_headers = default_headers.merge(headers)
    lines = all_headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    "HTTP/1.1 #{status} #{reason}\r\n#{lines}\r\n#{content}"
  end
end
