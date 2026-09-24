# frozen_string_literal: true

require 'cgi'
require 'json'
require 'socket'

# A live Bot API stand-in that refuses what Telegram refuses, so a send that fails in production fails here.
class TelegramBotApiFake
  MAX_TEXT = 4096
  HTML_TAGS = %w[b strong i em u ins s strike del code pre a blockquote tg-spoiler].freeze
  Call = Struct.new(:name, :params, :at, :ok, keyword_init: true)

  attr_reader :bot_id

  def initialize(bot_id: 7_000_000_001, username: 'tamoz_eval_bot')
    @bot_id = bot_id
    @username = username
    @server = TCPServer.new('127.0.0.1', 0)
    @lock = Mutex.new
    @arrived = ConditionVariable.new
    @updates = []
    @calls = []
    @messages = {}
    @update_id = 100
    @message_id = 1_000
    @running = true
    @acceptor = Thread.new { accept_loop }
  end

  def origin = "http://127.0.0.1:#{@server.addr[1]}"

  def stop
    @running = false
    @lock.synchronize { @arrived.broadcast }
    @server.close
    @acceptor.join(2)
  end

  def say(user_id, text, reply_to: nil)
    message = user_message(user_id, 'text' => text)
    message['reply_to_message'] = { 'message_id' => reply_to } if reply_to
    push('message' => message)
    message
  end

  def send_photo(user_id)
    push('message' => user_message(user_id, 'photo' => [{ 'file_id' => 'ph1', 'width' => 90, 'height' => 90 }]))
  end

  def tap(user_id, message_id, data)
    push('callback_query' => { 'id' => "cb#{next_update_id}", 'data' => data, 'from' => user(user_id),
                               'message' => { 'message_id' => message_id,
                                              'chat' => { 'id' => user_id, 'type' => 'private' } } })
  end

  def calls(since: 0, chat: nil)
    @lock.synchronize do
      @calls.select { |call| call.at >= since && (chat.nil? || call.params['chat_id'].to_s == chat.to_s) }
    end
  end

  # What the user sees: each message by id, with its latest text and buttons.
  def visible_messages(chat, since: 0)
    @lock.synchronize do
      @messages.values.select { |m| m[:chat].to_s == chat.to_s && m[:touched] >= since }.sort_by { |m| m[:id] }
    end
  end

  def message(id) = @lock.synchronize { @messages[id]&.dup }

  private

  def user(user_id) = { 'id' => user_id, 'is_bot' => false, 'first_name' => "User#{user_id}" }

  def user_message(user_id, fields)
    { 'message_id' => next_message_id, 'date' => Time.now.to_i, 'from' => user(user_id),
      'chat' => { 'id' => user_id, 'type' => 'private' } }.merge(fields)
  end

  def push(fields)
    @lock.synchronize do
      @updates << { 'update_id' => (@update_id += 1) }.merge(fields)
      @arrived.broadcast
    end
  end

  def next_update_id = @lock.synchronize { @update_id += 1 }
  def next_message_id = @lock.synchronize { @message_id += 1 }

  def accept_loop
    while @running
      socket = @server.accept
      Thread.new(socket) { |client| serve(client) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    line = socket.gets or return
    method = line.split[1].to_s.split('/').last
    params = read_body(socket)
    status, body = dispatch(method, params)
    payload = JSON.generate(body)
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    socket.close
  end

  def read_body(socket)
    length = 0
    while (header = socket.gets) && header != "\r\n"
      length = header.split(':', 2).last.to_i if header.downcase.start_with?('content-length:')
    end
    length.zero? ? {} : JSON.parse(socket.read(length))
  end

  def dispatch(method, params)
    case method
    when 'getMe' then ok('id' => @bot_id, 'is_bot' => true, 'username' => @username, 'first_name' => 'Tamoz')
    when 'getUpdates' then ok(long_poll(params))
    when 'sendMessage' then record(method, params) { send_message(params) }
    when 'editMessageText' then record(method, params) { edit_message(params) }
    when 'editMessageReplyMarkup' then record(method, params) { edit_markup(params) }
    when 'sendChatAction', 'answerCallbackQuery' then record(method, params) { ok(true) }
    else [404, { 'ok' => false, 'error_code' => 404, 'description' => 'Not Found' }]
    end
  end

  def ok(result) = [200, { 'ok' => true, 'result' => result }]
  def bad(description) = [400, { 'ok' => false, 'error_code' => 400, 'description' => "Bad Request: #{description}" }]

  def long_poll(params)
    offset = params['offset'].to_i
    deadline = Time.now + [params['timeout'].to_f, 25.0].min
    @lock.synchronize do
      @updates.reject! { |update| update['update_id'] < offset }
      @arrived.wait(@lock, deadline - Time.now) while @running && @updates.empty? && Time.now < deadline
      @updates.first(params.fetch('limit', 100))
    end
  end

  def record(method, params)
    status, body = yield
    @lock.synchronize { @calls << Call.new(name: method, params:, at: Time.now.to_f, ok: status == 200) }
    [status, body]
  end

  # What the phone shows: parse_mode HTML is parsed the way Telegram parses it,
  # and markup it cannot parse is refused, not shown raw.
  def rendered(params)
    text = params['text'].to_s
    return [text, nil] unless params['parse_mode'] == 'HTML'

    problem = html_problem(text)
    problem ? [nil, "can't parse entities: #{problem}"] : [CGI.unescapeHTML(text.gsub(/<[^>]*>/, '')), nil]
  end

  def html_problem(text)
    open = []
    text.scan(%r{<(/?)([a-z-]+)(?:\s[^>]*)?>|<|&(?!(?:lt|gt|amp|quot|#\d+);)}) do |closing, tag|
      return 'unescaped < or &' if tag.nil?
      return "unsupported tag <#{tag}>" unless HTML_TAGS.include?(tag)
      next open.push(tag) if closing.empty?
      return "unexpected </#{tag}>" unless open.pop == tag
    end
    "unclosed <#{open.last}>" unless open.empty?
  end

  def text_problem(text)
    return 'message text is empty' if text.to_s.strip.empty?

    'message is too long' if text.encode('UTF-16LE').bytesize / 2 > MAX_TEXT
  end

  def unchanged?(message, text, params) = message[:text] == text && message[:markup] == params['reply_markup']

  def revise(message, text, params)
    message[:text] = text
    message[:markup] = params['reply_markup']
    message[:touched] = Time.now.to_f
  end

  def send_message(params)
    text, problem = rendered(params)
    problem ||= text_problem(text)
    return bad(problem) if problem

    id = next_message_id
    @lock.synchronize do
      @messages[id] = { id:, chat: params['chat_id'], text:, markup: params['reply_markup'],
                        at: Time.now.to_f, touched: Time.now.to_f }
    end
    ok('message_id' => id, 'date' => Time.now.to_i, 'chat' => { 'id' => params['chat_id'] }, 'text' => text)
  end

  def edit_message(params)
    text, problem = rendered(params)
    problem ||= text_problem(text)
    return bad(problem) if problem

    @lock.synchronize do
      message = @messages[params['message_id'].to_i]
      return bad('message to edit not found') unless message
      return bad('message is not modified') if unchanged?(message, text, params)

      revise(message, text, params)
      ok('message_id' => message[:id], 'date' => Time.now.to_i, 'text' => text)
    end
  end

  def edit_markup(params)
    @lock.synchronize do
      message = @messages[params['message_id'].to_i]
      return bad('message to edit not found') unless message
      return bad('message is not modified') if message[:markup].to_h == params['reply_markup'].to_h

      message[:markup] = params['reply_markup']
      ok(true)
    end
  end
end
