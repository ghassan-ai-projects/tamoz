# frozen_string_literal: true

require_relative 'telegram_cli_fixture'
require 'socket'

# Scripted `tamoz start` runs: models that answer or refuse, stubbed launch points, and the children a start spawns.
module CliStartHarness
  include TelegramCliFixture

  KEYS = { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:test', 'ZAI_API_KEY' => 'chat-key',
           'OPENROUTER_SPEECH_API_KEY' => 'speech-key' }.freeze

  # A model that answers, or refuses with an HTTP status.
  class Model
    def initialize(status = nil) = @status = status

    def generate(**) = refuse || 'ok'
    def transcribe(**) = refuse || :ok
    def speak(**) = refuse || :ok

    def refuse
      raise Tamoz::Agent::ModelCallError.new(code: 'http_failure', status: @status) if @status
    end
  end

  def runtime_with(runtime, workspace, *setup, telegram: true, talk: false)
    cli(runtime, ['setup', '--workspace', workspace, *setup], bot: Bot.new([]))
    cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([])) if telegram
    cli(runtime, %W[channel add talk --port #{free_port}], bot: Bot.new([])) if talk
  end

  def free_port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }

  # stubs: chat: the chat model, speech: role -> model, bot: the Bot API.
  def start(runtime, *args, env: KEYS, **stubs)
    out = StringIO.new
    err = StringIO.new
    served = []
    status = start_cli(out, err, env, served, stubs).run(['--runtime-dir', runtime, 'start', *args])
    [status, out.string, err.string, served.last]
  end

  def start_cli(out, err, env, served, stubs)
    bot = stubs.fetch(:bot) { Bot.new([]) }
    cli = Tamoz::Agent::CLI.new(out:, err:, input: StringIO.new, env:,
                                channel_kinds: ChannelKindsFixture.telegram(lambda { |_token|
                                  bot
                                }),
                                model_factory: ->(**) { stubs.fetch(:chat) { Model.new } })
    stub_launch(cli, served, stubs)
  end

  def stub_launch(cli, served, stubs)
    speech = stubs.fetch(:speech) { ->(_role) { Model.new } }
    cli.define_singleton_method(:role_model) { |_base, role, _directory| speech.call(role) }
    cli.define_singleton_method(:serve) { |directory, base| (served << [directory, base]) && 0 }
    cli.define_singleton_method(:launch_agents) { stubs.fetch(:agents) { Dir.tmpdir } }
    cli.define_singleton_method(:launchctl) { |*| ['', nil] }
    cli
  end

  def config_path(runtime) = File.join(runtime, Tamoz::Agent::RuntimeDirectory::CONFIG_FILE)

  private

  def plain_cli(env = {})
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env:)
  end

  def resolved(runtime) = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {})

  def edit_config(runtime)
    document = Psych.safe_load_file(config_path(runtime))
    yield document
    File.write(config_path(runtime), Psych.dump(document))
  end

  def spawn_children_of(directory)
    cli = plain_cli(KEYS)
    spawned = {}
    cli.define_singleton_method(:spawn_child) { |name, env, args, _logs| (spawned[name] = [env, args]) && Process.pid }
    cli.send(:spawn_children, directory, KEYS.merge('TAMOZ_TALK_TOKEN' => 't' * 43), Dir.tmpdir)
    spawned
  end

  def hold_poller(runtime, surface, stream)
    plain_cli.send(:with_comms_runtime, { runtime_dir: runtime }) do |_directory, _adapter, store, _checkpoints|
      store.acquire_poller_lease(surface_id: surface, stream_id: stream,
                                 lease: Tamoz::Comms::Lease.new(owner: "gateway:#{Process.pid}", fence: 1).wire,
                                 ttl_s: 60,
                                 now: Time.now.utc)
    end
  end
end
