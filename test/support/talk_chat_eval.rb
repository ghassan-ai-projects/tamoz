# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'

# Drives the real `tamoz talk setup` and `tamoz talk start` and talks to the page's HTTP API exactly as the
# browser does (same routes, update ids, resend rule). With TalkFakeProvider it is plumbing; with real keys it
# is the eval's server-side layer.
class TalkChatEval
  ROOT = File.expand_path('../..', __dir__)
  EXE = File.join(ROOT, 'gems/tamoz-agent-cli/exe/tamoz')

  Event = Struct.new(:at, :data)

  attr_reader :runtime, :workspace, :events, :base

  def initialize(env:, workspace_files: {})
    @root = Dir.mktmpdir('tamoz-talk-eval')
    @runtime = File.join(@root, 'runtime')
    @workspace = File.join(@root, 'workspace')
    FileUtils.mkdir_p(@workspace)
    workspace_files.each { |name, text| File.write(File.join(@workspace, name), text) }
    @env = env
    @events = []
    @mutex = Mutex.new
  end

  def start(timeout: 60)
    @port = free_port
    out, status = Open3.capture2e(child_env, RbConfig.ruby, EXE, '--runtime-dir', @runtime, 'talk', 'setup',
                                  '--workspace', @workspace, '--port', @port.to_s)
    raise "talk setup failed: #{out}" unless status.success?

    @token = File.read(File.join(@runtime, 'talk', 'token')).strip
    @log = File.join(@root, 'start.log')
    @pid = Process.spawn(child_env, RbConfig.ruby, EXE, '--runtime-dir', @runtime, 'talk', 'start',
                         out: @log, err: @log, pgroup: true)
    wait_until(timeout, 'the talk page answers') { up? }
    @poller = Thread.new { poll_events }
    self
  end

  def stop
    @stopping = true
    @poller&.kill
    if @pid
      Process.kill('-TERM', Process.getpgid(@pid)) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(@pid) rescue nil # rubocop:disable Style/RescueModifier
    end
    FileUtils.rm_rf(@root) unless ENV['TAMOZ_TALK_EVAL_KEEP']
  end

  def start_log = File.exist?(@log.to_s) ? File.read(@log) : ''

  def new_update_id = (Time.now.to_f * 1_000_000).to_i + rand(1000)

  # @return [Integer] the HTTP status, after resending the same update id while it is 503
  def say_text(text,
               update_id: new_update_id)
    submit('/v1/messages', JSON.generate('update_id' => update_id, 'text' => text),
           'application/json')
  end

  def say_audio(wav, update_id: new_update_id) = submit("/v1/utterances?update_id=#{update_id}", wav, 'audio/wav')

  def decide(action, card)
    submit('/v1/decisions', JSON.generate('update_id' => new_update_id, 'action' => action,
                                          'reference' => card.fetch('reference'),
                                          'message_id' => card.fetch('message_id')), 'application/json')
  end

  def speech(message_id)
    response = request(Net::HTTP::Get.new("/v1/speech/#{message_id}"))
    [response.code.to_i, response.body.to_s.b]
  end

  def messages(since: 0) = @mutex.synchronize { @events.select { |e| e.at >= since && e.data['type'] == 'message' } }

  def await(timeout: Float(ENV.fetch('TAMOZ_TALK_AWAIT_S', 120)), since: 0, &predicate)
    wait_until(timeout, 'the expected event') { messages(since:).find { |event| yield(event.data) } }
  end

  def wait_until(timeout, what)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      raise "timed out waiting for #{what}\n#{start_log[-3000..] || start_log}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  private

  def child_env
    @env.merge('TAMOZ_RUNTIME_DIR' => nil, 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8',
               'RUBYLIB' => $LOAD_PATH.join(File::PATH_SEPARATOR))
  end

  def submit(path, body, type)
    20.times do
      post = Net::HTTP::Post.new(path, 'Content-Type' => type)
      post.body = body
      status = request(post, read_timeout: 30).code.to_i
      return status unless status == 503

      sleep 0.5
    end
    503
  end

  def poll_events
    epoch = ''
    after = 0
    until @stopping
      begin
        response = request(Net::HTTP::Get.new("/v1/events?after=#{after}&epoch=#{epoch}&timeout=10&speech=1"),
                           read_timeout: 15)
        page = JSON.parse(response.body)
        epoch = page.fetch('epoch')
        after = page.fetch('next')
        @mutex.synchronize { page.fetch('events').each { |event| @events << Event.new(now, event) } }
      rescue StandardError
        sleep 0.2
      end
    end
  end

  def up?
    request(Net::HTTP::Get.new('/v1/events?timeout=0'), read_timeout: 2).code == '200'
  rescue StandardError
    false
  end

  def request(message, read_timeout: 10)
    message['Authorization'] = "Bearer #{@token}"
    Net::HTTP.start('127.0.0.1', @port, read_timeout:, open_timeout: 2) { |http| http.request(message) }
  end

  def free_port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
end
