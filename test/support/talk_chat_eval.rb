# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'psych'
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
  FINAL = %w[answer failed stopped blocked].freeze
  # What one turn showed: its Heard notice, its final reply or approval card, and when each arrived.
  Turn = Struct.new(:sent_at, :voice, :admitted, :heard, :final, :card, :events, keyword_init: true) do
    def answer = final && final.data['kind'] == 'answer' ? final.data['text'] : nil
  end

  attr_reader :runtime, :workspace, :events, :base, :responses, :turns, :speech_times, :utterances

  def initialize(env:, workspace_files: {}, approval_profile: nil)
    @root = Dir.mktmpdir('tamoz-talk-eval')
    @runtime = File.join(@root, 'runtime')
    @workspace = File.join(@root, 'workspace')
    FileUtils.mkdir_p(@workspace)
    workspace_files.each { |name, text| File.write(File.join(@workspace, name), text) }
    @env = env
    @events = []
    @responses = []
    @turns = []
    @speech_times = []
    @utterances = 0
    @approval_profile = approval_profile
    @mutex = Mutex.new
  end

  def start(timeout: 60, args: [])
    @port = free_port
    out, status = Open3.capture2e(child_env, RbConfig.ruby, EXE, '--runtime-dir', @runtime, 'talk', 'setup',
                                  '--workspace', @workspace, '--port', @port.to_s)
    raise "talk setup failed: #{out}" unless status.success?

    tighten_approvals if @approval_profile
    @token = File.read(File.join(@runtime, 'talk', 'token')).strip
    @log = File.join(@root, 'start.log')
    @pid = Process.spawn(child_env, RbConfig.ruby, EXE, '--runtime-dir', @runtime, 'talk', 'start', *args,
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

  def page_url = "http://127.0.0.1:#{@port}/#token=#{@token}"

  def new_update_id = (Time.now.to_f * 1_000_000).to_i + rand(1000)

  # @return [Integer] the HTTP status, after resending the same update id while it is 503
  def say_text(text,
               update_id: new_update_id)
    submit('/v1/messages', JSON.generate('update_id' => update_id, 'text' => text),
           'application/json')
  end

  def say_audio(wav, update_id: new_update_id)
    submit("/v1/utterances?update_id=#{update_id}", wav, 'audio/wav').tap { |status| @utterances += 1 if status == 200 }
  end

  def decide(action, card)
    submit('/v1/decisions', JSON.generate('update_id' => new_update_id, 'action' => action,
                                          'reference' => card.fetch('reference'),
                                          'message_id' => card.fetch('message_id')), 'application/json')
  end

  def speech(message_id)
    started = now
    response = request(Net::HTTP::Get.new("/v1/speech/#{message_id}"), read_timeout: 30)
    @speech_times << (now - started) if response.code == '200'
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

  # Sends one utterance or text and waits for its final reply or an approval card.
  def turn(text: nil, wav: nil, timeout: Float(ENV.fetch('TAMOZ_TALK_AWAIT_S', 180)))
    sent_at = now
    status = wav ? say_audio(wav) : say_text(text)
    return Turn.new(sent_at:, voice: !wav.nil?, admitted: false, events: []) unless status == 200

    settled = begin
      await(timeout:, since: sent_at) { |event| FINAL.include?(event['kind']) || event['reference'] }
    rescue RuntimeError
      nil
    end
    seen = messages(since: sent_at)
    Turn.new(sent_at:, voice: !wav.nil?, admitted: true, events: seen,
             heard: seen.find { |event| event.data['text'].to_s.start_with?('Heard:') },
             final: settled && FINAL.include?(settled.data['kind']) ? settled : nil,
             card: settled && settled.data['reference'] ? settled : nil).tap { |turn| @turns << turn }
  end

  # Every earlier request has settled and nothing waits in the outbox, so the next scenario starts clean.
  def settle(timeout: 240)
    wait_until(timeout, 'the runtime to go idle') do
      query("SELECT (SELECT COUNT(*) FROM tamoz_comms_requests WHERE projection_state = 'admitted') + " \
            "(SELECT COUNT(*) FROM tamoz_comms_outbox WHERE status IN ('pending', 'claimed'))").first.to_i.zero?
    end
  end

  def fresh_thread
    settle
    since = now
    say_text('/new')
    await(timeout: 30, since:) { |event| event['kind'] == 'control' }
  rescue RuntimeError
    nil
  end

  def query(sql)
    out, = Open3.capture2('sqlite3', '-readonly', File.join(@runtime, 'runtime.sqlite3'), sql)
    out.split("\n")
  end

  def workspace_digest
    Dir.glob(File.join(@workspace, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
       .map { |path| "#{path.delete_prefix(@workspace)}:#{Digest::SHA256.file(path).hexdigest}" }.join("\n")
  end

  private

  # The default profile lets chat tools write without asking; like the Telegram eval, a write must really ask.
  def tighten_approvals
    path = File.join(@runtime, 'config.yaml')
    document = Psych.safe_load_file(path, aliases: false)
    document['approval'] = { 'profile' => @approval_profile }
    File.write(path, Psych.dump(document))
  end

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
    response = Net::HTTP.start('127.0.0.1', @port, read_timeout:, open_timeout: 2) { |http| http.request(message) }
    @mutex.synchronize { @responses << [message.path, response.to_hash.to_s + response.body.to_s.b] }
    response
  end

  def free_port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
end
