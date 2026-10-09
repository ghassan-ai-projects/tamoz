# frozen_string_literal: true

require 'json'
require 'socket'

# An OpenAI-compatible stand-in for the three talk roles: chat, speech-to-text and speech. Plumbing only.
class TalkFakeProvider
  MP3 = "ID3\x04\x00\x00\x00\x00\x00\x00\xFF\xFBfake-speech".b

  attr_reader :requests

  def initialize(answer: ->(_text) { 'Pond 7 is fine.' }, heard: 'check pond seven')
    @answer = answer
    @heard = heard
    @requests = Queue.new
    @server = TCPServer.new('127.0.0.1', 0)
  end

  def base_url = "http://127.0.0.1:#{@server.addr[1]}/v1"

  def start
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      rescue IOError, SystemCallError
        break
      end
    end
    self
  end

  def stop
    @server.close
    @thread&.join(1)
  end

  private

  def serve(socket)
    head = +''
    head << socket.gets until head.end_with?("\r\n\r\n")
    path = head[/\APOST (\S+)/, 1]
    body = socket.read(head[/content-length: (\d+)/i, 1].to_i)
    @requests << path
    status, type, payload = respond(path, body)
    socket.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{payload.bytesize}\r\n" \
                 "Connection: close\r\n\r\n".b + payload.b)
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close
  end

  def respond(path, body)
    case path
    when %r{/audio/transcriptions\z} then ['200 OK', 'application/json', JSON.generate('text' => @heard)]
    when %r{/audio/speech\z} then ['200 OK', 'audio/mpeg', MP3]
    else ['200 OK', 'application/json', JSON.generate(chat(JSON.parse(body)))]
    end
  end

  def chat(request)
    last = Array(request['messages']).reverse.find { |message| message['role'] == 'user' }
    content = request['response_format'] ? '{"ok":true}' : @answer.call(last && last['content'].to_s)
    { 'id' => 'fake', 'model' => request['model'], 'choices' => [{ 'index' => 0, 'finish_reason' => 'stop',
                                                                   'message' => { 'role' => 'assistant', 'content' => content } }],
      'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 5, 'total_tokens' => 15 } }
  end
end
