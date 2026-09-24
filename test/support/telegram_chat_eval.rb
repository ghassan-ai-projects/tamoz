# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'psych'
require 'rbconfig'
require 'stringio'
require 'timeout'
require 'tmpdir'

require 'tamoz/agent_cli'
require 'tamoz/telegram'
require_relative 'telegram_bot_api_fake'

# Drives the real gateway and worker against a fake Bot API; see docs/telegram-chat/GOAL.md.
# rubocop:disable Metrics/ClassLength -- one collaborator per concern (processes, the
#   fake, DB observations, settlement, reporting); splitting it would scatter the settle
#   rules every scenario depends on.
class TelegramChatEval
  ROOT = File.expand_path('../..', __dir__)
  EXE = File.join(ROOT, 'gems/tamoz-agent-cli/exe/tamoz')
  HYGIENE = [
    [/\br[0-9a-f]{10}\b/, 'request reference'],
    [/\b(Verified|Response only|Not verified): result\b/, 'verification label'],
    [/Committed progress|Next action:|Now: .* Next: /, 'progress trailer'],
    [/\b(effect_unknown|effect_key|occurrence_id|request_id|execution_id)\b|sha256:\h{8}/, 'internal vocabulary'],
    [/\A\s*[{\[]/, 'raw JSON']
  ].freeze
  ROUTING_FLAGS = { 'experimental' => '--experimental-routing', 'work' => '--work-routing',
                    'adaptive' => '--adaptive-routing' }.freeze
  USERS = (1001..1040).to_a.freeze
  STRANGER = 9_999
  # How long a turn may take, how long the chat must stay quiet to count as
  # finished, and whether work was unblocked by a tap (which delivers its answer
  # after the approval ack).
  SettleWindow = Struct.new(:timeout, :quiet, :awaiting_work, keyword_init: true) do
    def quiet = self[:quiet] || 2.5
  end

  class ProcessDied < StandardError; end

  Turn = Struct.new(:user, :text, :sent_at, :messages, :calls, :settled_at, :steps, keyword_init: true) do
    def reply = messages.map { |message| message[:text] }.join("\n")
    def sends = calls.count { |call| call.name == 'sendMessage' }
    def refused = calls.reject(&:ok)
    def typing = calls.count { |call| call.name == 'sendChatAction' }
    def answer_s = settled_at - sent_at

    def first_reply_s
      first = calls.find { |call| call.name == 'sendMessage' }
      first && (first.at - sent_at)
    end

    def button(prefix)
      messages.each do |message|
        Array(message.dig(:markup, 'inline_keyboard')).flatten.each do |key|
          return [message[:id], key['callback_data']] if key['callback_data'].to_s.start_with?(prefix)
        end
      end
      nil
    end
  end

  attr_reader :fake, :results, :transcript, :setup

  def initialize(provider:, model:, routing:)
    @provider = provider
    @model = model
    @routing = routing
    @root = Dir.mktmpdir('tamoz-telegram-eval')
    @workspace = File.join(@root, 'workspace')
    @runtime = File.join(@root, 'runtime')
    @fake = TelegramBotApiFake.new
    @results = []
    @transcript = []
    @pids = {}
    @users = USERS.dup
    provision
  end

  def label = "#{@provider}/#{@model} routing=#{@routing || 'legacy'}"

  def fresh_user = @users.shift

  def provider_key_name = "#{@provider.upcase}_API_KEY"

  def start
    restart_gateway
    wait_until('gateway deployed') { rows('select surface_id from tamoz_comms_surfaces').any? }
    start_worker
  end

  def start_worker(env = {})
    spawn_child(:worker, [EXE, '--runtime-dir', @runtime, '--provider', @provider, '--model', @model,
                          *ROUTING_FLAGS[@routing], 'worker', '--json'], env)
    wait_until('worker started') { log_tail(:worker, 200).include?('worker.started') }
  end

  def restart_worker(env)
    stop_worker
    start_worker(env)
  end

  def stop_worker = stop_child(:worker)

  def restart_gateway
    stop_child(:gateway)
    spawn_child(:gateway, [File.join(ROOT, 'script/telegram_chat_eval'), '--gateway', @fake.origin,
                           '--runtime-dir', @runtime, 'comms', 'serve'])
  end

  # Sends without waiting for the reply, for scenarios that act while a turn runs.
  def say(user, text) = @fake.say(user, text)

  def wait_for(what, timeout: 60, &) = wait_until(what, timeout:, &)

  def shutdown
    @logs = %i[gateway worker].to_h { |name| [name, log_tail(name)] }
    %i[gateway worker].each { |name| stop_child(name) }
    @fake.stop
  end

  # A tap on Approve resumes work whose answer follows the ack; a Deny only closes the request.
  def turn(user, text = nil, photo: false, tap: nil, timeout: 180)
    resumes = tap&.last.to_s.start_with?('approve:')
    sent_at = Time.now.to_f
    if tap then @fake.tap(user, *tap)
    elsif photo then @fake.send_photo(user)
    else @fake.say(user, text)
    end
    settle_and_record(user, tap ? "(tap #{tap.last})" : text || '(photo)', sent_at,
                      SettleWindow.new(timeout:, awaiting_work: resumes))
  end

  # A command sent while other work runs: judged on its own first reply, not on the chat settling.
  def command(user, text, timeout: 15)
    sent_at = Time.now.to_f
    @fake.say(user, text)
    wait_until("reply to #{text}", timeout:) { first_send(user, sent_at) }
    record_turn(user, text, sent_at, first_send(user, sent_at).at)
  end

  # Records whatever arrives from `since` until the chat settles.
  def await(user, label, since:, timeout: 180)
    settle_and_record(user, label, since, SettleWindow.new(timeout:))
  end

  def buttons?(message_id)
    Array(@fake.message(message_id)&.dig(:markup, 'inline_keyboard')).flatten.any?
  end

  def burst(user, texts, timeout: 240)
    sent_at = Time.now.to_f
    texts.each { |text| @fake.say(user, text) }
    settle_and_record(user, texts.join(' ⏎ '), sent_at, SettleWindow.new(timeout:, quiet: 4))
  end

  def check(scenario, name, pass, detail = nil)
    @results << { scenario:, check: name, pass: pass ? true : false, detail: detail.to_s.gsub(/\s+/, ' ')[0, 200] }
  end

  # Every text the chat showed, including versions later edited away.
  def hygiene(scenario, turns)
    texts = turns.flat_map(&:calls).filter_map { |call| call.params['text'] }
    offences = texts.flat_map { |text| HYGIENE.select { |pattern, _| text =~ pattern }.map(&:last) }
    check(scenario, 'no internal jargon', offences.empty?, offences.uniq.join(', '))
    refused = turns.flat_map(&:refused)
    check(scenario, 'every send accepted by Telegram', refused.empty?, refused.map(&:name).join(', '))
  end

  def workspace_text(name)
    path = File.join(@workspace, name)
    File.exist?(path) ? File.read(path) : ''
  end

  def settles(user)
    rows("select projection_state from tamoz_comms_requests where conversation_id = '#{chat(user)}' " \
         'order by created_at_ms')
  end

  def inbound_dispositions(user)
    rows("select disposition from tamoz_comms_inbound where correspondent_id = 'telegram:user:#{user}'")
  end

  # A request is still open or a send is queued in this chat. While the chat
  # shows a button, an open request waits on the person, so it does not count.
  def busy?(user, waiting_on_user: false)
    open = '0'
    unless waiting_on_user
      open = "(select count(*) from tamoz_comms_requests where conversation_id = '#{chat(user)}' " \
             "and projection_state = 'admitted')"
    end
    count = query("select #{open} + (select count(*) from tamoz_comms_outbox where conversation_id = " \
                  "'#{chat(user)}' and status in ('pending','claimed'))")
    count.nil? || count.to_i.positive?
  end

  def ensure_children_alive
    @pids.each do |name, pid|
      raise ProcessDied, "#{name} exited: #{log_tail(name, 3).strip}" if Process.wait(pid, Process::WNOHANG)
    end
  end

  def write_report(directory)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'report.md'), report)
    File.write(File.join(directory, 'results.json'), JSON.pretty_generate(@results))
    File.write(File.join(directory, 'process-logs.txt'),
               @logs.to_h.map { |name, text| "== #{name} ==\n#{text}" }.join("\n"))
  end

  private

  # The runtime is written by the documented one command (S1), not by hand: the
  # gateway and worker below then run on exactly what `tamoz telegram setup`
  # produced. Two operator edits follow, both of which a real operator makes:
  # the allowlist is widened the way a teammate is added, and the approval
  # profile is tightened to `unattended` so a workspace write really asks --
  # which is the only way the Approve button (D1) can appear at all.
  def provision
    FileUtils.mkdir_p(@workspace)
    File.write(File.join(@workspace, 'README.md'),
               "# Orchard\n\nA small demo project.\n\nProject codename: BLUE-HERON-42\nOwner: the platform team\n")
    File.write(File.join(@workspace, 'todo.txt'), "- water the plants\n- renew passport\n")
    FileUtils.mkdir_p(@runtime, mode: 0o700)
    @setup = run_setup
    widen_allowlist
    ask_before_changes
  end

  def run_setup
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(
      ['--runtime-dir', @runtime, 'telegram', 'setup', '--workspace', @workspace, '--owner', USERS.first.to_s],
      out:, err:, input: StringIO.new, env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:eval' },
      comms_client_factory: ->(token) { Tamoz::Telegram::Client.new(token, origin: @fake.origin) }
    )
    directory = Tamoz::Agent::RuntimeDirectory.resolve(path: @runtime, env: {})
    { status:, out: out.string, err: err.string, channel: directory.channels.fetch('telegram'),
      profile: File.join(directory.profiles_path, 'telegram.yaml') }
  end

  def edit_config
    path = File.join(@runtime, 'config.yaml')
    document = Psych.safe_load_file(path, aliases: false)
    yield document
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end

  def widen_allowlist
    edit_config do |document|
      document.fetch('channels').fetch('telegram')['admission']['correspondents'] =
        USERS.map { |id| "telegram:user:#{id}" }
    end
  end

  def ask_before_changes
    edit_config { |document| document['approval'] = { 'profile' => 'unattended' } }
  end

  def chat(user) = "telegram:chat:#{user}"

  def query(sql)
    out, _err, status = Open3.capture3('sqlite3', '-readonly', File.join(@runtime, 'runtime.sqlite3'), sql)
    status.success? ? out.strip : nil
  end

  def rows(sql) = query(sql).to_s.split("\n")

  def child_env(extra)
    { 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8', 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:eval',
      provider_key_name => secret(provider_key_name).to_s }.merge(extra)
  end

  def secret(name)
    ENV[name] || File.read(File.join(ROOT, '.env'))[/^#{name}\s*=\s*(\S+)/, 1]
  rescue Errno::ENOENT
    nil
  end

  def spawn_child(name, args, env = {})
    log = File.join(@root, "#{name}.log")
    @pids[name] = Process.spawn(child_env(env), RbConfig.ruby, *args, out: log, err: log, chdir: ROOT)
  end

  def stop_child(name)
    pid = @pids.delete(name) or return
    Process.kill('TERM', pid)
    Process.kill('KILL', pid) unless exited_within?(pid, 8)
  rescue Errno::ESRCH
    nil
  end

  def exited_within?(pid, seconds)
    deadline = Time.now + seconds
    while Time.now < deadline
      return true if Process.wait(pid, Process::WNOHANG)

      sleep 0.2
    end
    false
  rescue Errno::ECHILD
    true
  end

  def settle_and_record(user, text, sent_at, window)
    wait_settled(user, sent_at, window)
    record_turn(user, text, sent_at, Time.now.to_f)
  end

  def record_turn(user, text, sent_at, settled_at)
    calls = @fake.calls(since: sent_at, chat: user).select { |call| call.at <= settled_at }
    messages = @fake.visible_messages(user, since: sent_at - 0.01).select { |message| message[:at] <= settled_at }
    turn = Turn.new(user:, text:, sent_at:, settled_at:, messages:, calls:, steps: steps(user, sent_at, settled_at))
    @transcript << turn
    turn
  end

  # What the worker did for this turn, from the effect journal: model calls and tools, in order.
  def steps(user, from, to)
    rows("select replace(replace(operation, 'model.converse.', 'model:'), 'tool.', '') from tamoz_effects " \
         "where thread_id in (select thread_id from tamoz_comms_requests where conversation_id = '#{chat(user)}') " \
         "and created_at_ms between #{(from * 1000).to_i} and #{(to * 1000).to_i} order by created_at_ms")
  end

  def first_send(user, since) = @fake.calls(since:, chat: user).find { |call| call.name == 'sendMessage' }

  # Settled: nothing open, nothing queued to send, and the chat has been quiet.
  # After a tap the approval itself must also have left the paused projection, or
  # the turn is judged while the work it unblocked is still running.
  def wait_settled(user, since, window)
    deadline = Time.now + window.timeout
    until settled?(user, since, window)
      raise Timeout::Error, "chat #{user} still busy after #{window.timeout}s" if Time.now > deadline

      ensure_children_alive
      sleep 0.3
    end
  end

  # A tap resolves a prompt the chat was waiting on, so the reply that follows it
  # arrives without buttons; waiting_on_user must be judged on the LATEST send,
  # not on any send in the window, or the pre-tap prompt makes the turn look
  # settled while the resumed work is still running.
  def settled?(user, since, window)
    calls = @fake.calls(since:, chat: user)
    quiet = window.quiet
    return false if calls.empty? || Time.now.to_f - [since, *calls.map(&:at)].max <= quiet
    return false if window.awaiting_work && !approval_resolved?(user, since)

    !busy?(user, waiting_on_user: calls.last.params['reply_markup'])
  end

  # A tap turn sends the approval ack first and the resumed turn's answer second.
  # The request projection turns terminal a moment BEFORE that answer is
  # delivered, so the delivered second message is what proves the work finished;
  # counting every message in the conversation would be satisfied by the ack plus
  # the earlier prompt.
  def approval_resolved?(user, since)
    sends = @fake.calls(since:, chat: user).count { |call| call.name == 'sendMessage' }
    sends > 1 && !busy?(user)
  end

  def wait_until(what, timeout: 60)
    deadline = Time.now + timeout
    until yield
      ensure_children_alive
      raise Timeout::Error, "timed out: #{what}" if Time.now > deadline

      sleep 0.2
    end
  end

  def log_tail(name, lines = 20)
    File.readlines(File.join(@root, "#{name}.log")).last(lines).join
  rescue Errno::ENOENT
    ''
  end

  def report
    passed = @results.count { |result| result[:pass] }
    lines = ["# Telegram chat eval — #{label}", '', "**#{passed}/#{@results.length} checks pass.**", '',
             '| scenario | check | result | detail |', '|---|---|---|---|']
    @results.each do |result|
      lines << "| #{result[:scenario]} | #{result[:check]} | #{result[:pass] ? 'pass' : '**FAIL**'} | " \
               "#{result[:detail].to_s.tr('|', '/')[0, 140]} |"
    end
    lines += ['', '## Transcript', '']
    @transcript.each { |turn| lines.concat(transcript_lines(turn)) }
    lines.join("\n")
  end

  def transcript_lines(turn)
    first = turn.first_reply_s ? format('%.1fs', turn.first_reply_s) : '—'
    ["**user #{turn.user}:** #{turn.text}  _(first reply #{first}, settled " \
     "#{format('%.1fs', turn.answer_s)}, #{turn.sends} msgs, #{turn.typing} typing)_",
     *(turn.steps.empty? ? [] : ["_steps: #{turn.steps.join(' → ')}_"]),
     *turn.messages.map { |message| message_line(message) }, '']
  end

  def message_line(message)
    keys = Array(message.dig(:markup, 'inline_keyboard')).flatten.map { |key| key['text'] }
    buttons = keys.empty? ? '' : "  [buttons: #{keys.join(', ')}]"
    "> #{message[:text].to_s[0, 1200].gsub("\n", "\n> ")}#{buttons}"
  end
end
# rubocop:enable Metrics/ClassLength
