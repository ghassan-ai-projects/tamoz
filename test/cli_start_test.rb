# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_cli_fixture'
require 'socket'

# `tamoz start` checks a runtime's channels and models with scripted calls, then runs a gateway per channel and one
# worker; nothing here spawns a process or calls a real model.
class CliStartTest < Minitest::Test
  include TelegramCliFixture

  CHAT = %w[--chat zai/glm-5.3-flash].freeze
  SPEECH = %w[--transcription openrouter/openai/gpt-4o-mini-transcribe --transcription-credential
              OPENROUTER_SPEECH_API_KEY --voice openrouter/hexgrad/kokoro-82m --voice-name af_heart
              --voice-credential OPENROUTER_SPEECH_API_KEY].freeze
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
    cli = Tamoz::Agent::CLI.new(out:, err:, input: StringIO.new, env:, channel_kinds: ChannelKindsFixture.telegram(lambda { |_token|
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

  def test_a_runtime_with_telegram_and_talk_starts_both_with_its_chat_model
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, talk: true)
      status, out, err, served = start(runtime)

      assert_equal 0, status, err
      assert_includes out, 'Tamoz is starting telegram, talk with zai/glm-5.3-flash.'
      refute_nil served
    end
  end

  def test_the_talk_link_is_printed_and_the_token_goes_to_the_talk_gateway
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      _status, out, = start(runtime)
      token = File.read(File.join(runtime, 'channels', 'talk', 'token')).strip
      spawned = spawn_children_of(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}))

      assert_includes out, "/#token=#{token}"
      assert_equal token, spawned.dig('talk-gateway', 0, 'TAMOZ_TALK_TOKEN')
    end
  end

  def test_one_gateway_per_channel_and_one_worker_without_model_flags
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, talk: true)
      spawned = spawn_children_of(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}))

      assert_equal({ 'telegram-gateway' => %w[comms serve --surface telegram],
                     'talk-gateway' => %w[comms serve --surface talk], 'worker' => %w[--work-routing worker --json] },
                   spawned.transform_values { |(_env, args)| args.drop(2) })
    end
  end

  def test_each_child_gets_its_own_environment
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, talk: true)
      spawned = spawn_children_of(Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}))

      assert_equal(%w[TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_TALK_TOKEN ZAI_API_KEY],
                   [spawned.dig('telegram-gateway', 0), spawned.dig('talk-gateway', 0), spawned.dig('worker', 0)]
                     .zip(%w[TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_TALK_TOKEN
                             ZAI_API_KEY]).map { |env, key| env.key?(key) && key })
    end
  end

  def test_a_voice_whose_key_is_missing_leaves_the_page_text_only
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

      assert_nil cli.send(:voice_synthesizer, Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}))
    end
  end

  def test_a_disabled_channel_is_neither_checked_nor_served
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, talk: true)
      document = Psych.safe_load_file(config_path(runtime))
      document['channels']['telegram']['enabled'] = false
      File.write(config_path(runtime), Psych.dump(document))
      status, _out, err, (directory,) = start(runtime, env: KEYS.except('TAMOZ_TELEGRAM_BOT_TOKEN'))

      assert_equal 0, status, err
      assert_equal %w[talk-gateway worker], spawn_children_of(directory).keys
    end
  end

  def test_the_worker_never_gets_a_variable_a_disabled_channel_names
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)
      document = Psych.safe_load_file(config_path(runtime))
      document['channels']['telegram'].merge!('enabled' => false,
                                              'credential_ref' => { 'kind' => 'env', 'name' => 'OLD_BOT_TOKEN' })
      document['sources'] = { 'websearch' => { 'enabled' => true, 'command' => '/opt/websearch',
                                               'credential_refs' => %w[OLD_BOT_TOKEN] } }
      File.write(config_path(runtime), Psych.dump(document))
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {})
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: KEYS)

      worker, = cli.send(:child_plan, directory, KEYS.merge('OLD_BOT_TOKEN' => 'old')).fetch('worker')

      refute worker.key?('OLD_BOT_TOKEN')
    end
  end

  def test_a_runtime_inside_its_workspace_is_refused
    with_dirs do |_runtime, workspace|
      runtime = File.join(workspace, '.tamoz')
      runtime_with(runtime, workspace, *CHAT)
      status, _out, err, served = start(runtime)

      assert_equal [1, nil], [status, served]
      assert_includes err, 'inside the workspace'
    end
  end

  def test_a_runtime_without_a_channel_is_sent_to_channel_add
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, telegram: false)

      assert_includes start(runtime)[2], '`tamoz channel add telegram`'
    end
  end

  def test_a_runtime_without_a_chat_model_is_sent_to_setup
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace)

      assert_includes start(runtime)[2], '`tamoz setup --chat PROVIDER/MODEL`'
    end
  end

  def test_a_missing_env_file_is_named
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)

      assert_includes start(runtime, '--env-file', File.join(workspace, 'nope.env'))[2], 'cannot read --env-file'
    end
  end

  def test_a_missing_bot_token_is_named
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)

      assert_includes start(runtime, env: KEYS.except('TAMOZ_TELEGRAM_BOT_TOKEN'))[2], 'set TAMOZ_TELEGRAM_BOT_TOKEN'
    end
  end

  def test_a_revoked_bot_token_is_named
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)
      revoked = Object.new
      revoked.define_singleton_method(:call) { |*| raise Tamoz::Comms::AuthenticationError, 'unauthorized' }

      assert_includes start(runtime, bot: revoked)[2], 'refused the bot token'
    end
  end

  def test_a_channel_another_run_holds_is_refused_naming_it
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)
      hold_poller(runtime, 'telegram', BOT.fetch('id'))
      status, _out, err, = start(runtime)

      assert_equal 1, status
      assert_includes err, "already running for this channel (pid #{Process.pid})"
    end
  end

  def test_a_talk_channel_another_run_holds_is_refused_naming_it
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      hold_poller(runtime, 'talk',
                  Psych.safe_load_file(config_path(runtime)).dig('channels', 'talk', 'expected_bot_id'))

      assert_includes start(runtime)[2], "already running for this channel (pid #{Process.pid})"
    end
  end

  def test_a_chat_model_that_refuses_is_named_and_nothing_runs
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT)
      status, _out, err, served = start(runtime, chat: Model.new(402))

      assert_equal [1, nil], [status, served]
      assert_includes err, 'the chat model zai/glm-5.3-flash (ZAI_API_KEY): the account is out of credit'
    end
  end

  def test_the_talk_page_needs_a_speech_to_text_model
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, telegram: false, talk: true)

      assert_includes start(runtime)[2], '`tamoz setup --transcription PROVIDER/MODEL`'
    end
  end

  def test_a_speech_to_text_model_that_fails_stops_the_start
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      status, _out, err, = start(runtime, speech: ->(_role) { Model.new(500) })

      assert_equal 1, status
      assert_includes err, 'the speech-to-text model did not answer'
    end
  end

  def test_a_failing_voice_warns_and_runs_text_only
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      voice_down = ->(role) { Model.new(role == 'VOICE' ? 500 : nil) }
      status, _out, err, served = start(runtime, speech: voice_down)

      assert_equal 0, status
      assert_includes err, 'the voice model did not answer'
      refute_nil served
    end
  end

  def test_the_chat_key_is_refused_as_the_voice_key_by_name
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, '--voice-credential', 'ZAI_API_KEY', telegram: false, talk: true)

      assert_includes start(runtime, env: KEYS.except('ZAI_API_KEY'))[2], "must not be the chat model's key"
    end
  end

  def test_the_chat_key_is_refused_as_the_voice_key_by_value
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)

      assert_includes start(runtime, env: KEYS.merge('OPENROUTER_SPEECH_API_KEY' => 'chat-key'))[2],
                      "must not be the chat model's key"
    end
  end

  def test_a_network_address_needs_an_allowed_host
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)

      assert_includes cli(runtime, %w[channel add talk --host 0.0.0.0], bot: Bot.new([]))[2], '--allow-host'
    end
  end

  def test_an_allowed_host_warns_of_clear_text_and_links_by_its_name
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      cli(runtime, %w[channel add talk --allow-host mac.tail.ts.net --host 0.0.0.0], bot: Bot.new([]))
      status, out, err, = start(runtime)

      assert_equal 0, status, err
      assert_includes err, 'clear text'
      assert_includes out, 'https://mac.tail.ts.net/#token='
    end
  end

  def test_a_damaged_talk_token_is_named
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      File.write(File.join(runtime, 'channels', 'talk', 'token'), "short\n")

      assert_includes start(runtime)[2], 'the talk token is missing or damaged'
    end
  end

  def test_a_taken_talk_port_is_named_before_the_link_is_printed
    with_dirs do |runtime, workspace|
      runtime_with(runtime, workspace, *CHAT, *SPEECH, telegram: false, talk: true)
      port = Psych.safe_load_file(config_path(runtime)).dig('channels', 'talk', 'settings', 'port')
      TCPServer.open('127.0.0.1', port) do
        _status, out, err, = start(runtime)

        assert_includes err, "cannot listen on 127.0.0.1:#{port}"
        refute_includes out, '#token='
      end
    end
  end

  def test_help_lists_the_options
    with_dirs do |runtime, _workspace|
      status, out, = cli(runtime, %w[start --help], bot: Bot.new([]))

      assert_equal 0, status
      assert_includes out, '--env-file PATH'
    end
  end

  private

  def spawn_children_of(directory)
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: KEYS)
    spawned = {}
    cli.define_singleton_method(:spawn_child) { |name, env, args, _logs| (spawned[name] = [env, args]) && Process.pid }
    cli.send(:spawn_children, directory, KEYS.merge('TAMOZ_TALK_TOKEN' => 't' * 43), Dir.tmpdir)
    spawned
  end

  def hold_poller(runtime, surface, bot_id)
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
                     .send(:with_comms_runtime, { runtime_dir: runtime }) do |_directory, _adapter, store, _checkpoints|
      store.acquire_poller_lease(surface_id: surface, bot_id:, owner: "gateway:#{Process.pid}", fence: 1, ttl_s: 60,
                                 now: Time.now.utc)
    end
  end
end
