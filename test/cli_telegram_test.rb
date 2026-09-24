# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# `tamoz telegram setup|start` against a scripted Bot API client and scripted models.
# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions -- one command
#   writes several fields; asserting them together is one test of one command.
class CliTelegramTest < Minitest::Test
  BOT = { 'id' => 7_000_000_001, 'username' => 'tamoz_test_bot', 'is_bot' => true }.freeze
  OWNER = 5_640_479_090

  class Bot
    attr_reader :calls

    def initialize(updates)
      @updates = updates
      @calls = []
    end

    def origin = 'https://api.telegram.org'

    def call(method, params, idempotent: false) # rubocop:disable Lint/UnusedMethodArgument
      @calls << [method, params]
      case method
      when 'getMe' then BOT
      when 'getWebhookInfo' then { 'url' => '' }
      when 'getUpdates' then @updates.shift(@updates.length).select { |u| u['update_id'] >= params['offset'].to_i }
      else { 'message_id' => 1, 'date' => 1 }
      end
    end
  end

  def test_setup_pairs_the_first_private_sender_and_writes_a_runnable_channel
    with_dirs do |runtime, workspace|
      bot = Bot.new([{ 'update_id' => 5, 'message' => { 'chat' => { 'id' => OWNER, 'type' => 'private' },
                                                        'from' => { 'id' => OWNER, 'first_name' => 'Ghassan' },
                                                        'text' => '/start' } }])
      status, out, err = cli(runtime, %W[telegram setup --workspace #{workspace}], bot:, input: "y\n")

      assert_equal 0, status, err
      assert_includes out, 'Paired with Telegram user'
      channel = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}).channels.fetch('telegram')

      assert_equal BOT.fetch('id'), channel.fetch('expected_bot_id')
      assert_equal ["telegram:user:#{OWNER}"], channel.dig('admission', 'correspondents')
      assert_includes bot.calls, ['getUpdates', { 'offset' => 6, 'timeout' => 0 }], 'the pairing message is consumed'
      assert(bot.calls.any? { |method, params| method == 'sendMessage' && params['chat_id'] == OWNER })
      assert_equal 0, cli(runtime, %w[comms doctor], bot:)[0], 'the written surface passes the doctor'
    end
  end

  def test_setup_does_not_pair_a_sender_the_operator_rejects
    with_dirs do |runtime, workspace|
      bot = Bot.new([{ 'update_id' => 5, 'message' => { 'chat' => { 'id' => 42, 'type' => 'private' },
                                                        'from' => { 'id' => 42, 'first_name' => 'Stranger' } } }])
      status, _out, err = cli(runtime, %W[telegram setup --workspace #{workspace}], bot:, input: "n\n")

      assert_equal 1, status
      assert_includes err, 'not paired'
      assert_empty Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}).channels
    end
  end

  def test_setup_without_a_token_says_where_the_token_comes_from
    with_dirs do |runtime, workspace|
      status, _out, err = cli(runtime, %W[telegram setup --workspace #{workspace}], bot: Bot.new([]), env: {})

      assert_equal 1, status
      assert_includes err, '@BotFather'
    end
  end

  def test_setup_reads_the_token_from_an_env_file
    with_dirs do |runtime, workspace|
      env_file = File.join(workspace, '.env')
      File.write(env_file, "export TAMOZ_TELEGRAM_BOT_TOKEN='123:from-file'\n")
      argv = %W[telegram setup --workspace #{workspace} --owner #{OWNER} --env-file #{env_file}]
      status, out, err = cli(runtime, argv, bot: Bot.new([]), env: {})

      assert_equal 0, status, err
      assert_includes out, "Paired with Telegram user #{OWNER}"
    end
  end

  def test_start_skips_a_provider_that_refuses_and_names_why
    with_dirs do |runtime, workspace|
      cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))
      refusing = { 'deepseek' => 402, 'openrouter' => nil }
      factory = lambda do |options|
        status = refusing.fetch(options.fetch(:provider))
        Struct.new(:status) do
          def generate(**)
            raise Tamoz::Agent::ModelCallError.new(code: 'http_failure', status:) if status

            'ok'
          end
        end.new(status)
      end
      out, err = capture_start(runtime, factory, 'DEEPSEEK_API_KEY' => 'dk', 'OPENROUTER_API_KEY' => 'ok')

      assert_includes err, 'deepseek/deepseek-chat: the account is out of credit'
      assert_equal %w[openrouter deepseek/deepseek-v4.1-flash], out
    end
  end

  def test_start_before_setup_says_to_run_setup
    with_dirs do |runtime, workspace|
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace:)
      status, _out, err = cli(runtime, %w[telegram start], bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, 'tamoz telegram setup'
    end
  end

  # The owner's half-finished runtime: a channel with no bot id, a profile that
  # was never written, and no profiles directory at all.
  def test_setup_repairs_an_existing_unpinned_channel_without_a_profiles_directory
    with_dirs do |runtime, workspace|
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace:)
      write_unpinned_channel(runtime)

      status, out, err = cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))

      assert_equal 0, status, err
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {})
      channel = directory.channels.fetch('telegram-ghassan')

      assert_equal ['telegram-ghassan'], directory.channels.keys, 'the unpinned channel is repaired, not duplicated'
      assert_equal BOT.fetch('id'), channel.fetch('expected_bot_id')
      assert_equal 'telegram', channel.fetch('profile')
      assert_path_exists File.join(directory.profiles_path, 'telegram.yaml')
      assert_includes out, 'telegram-ghassan'
    end
  end

  def test_setup_reports_a_transient_telegram_failure_without_a_backtrace
    with_dirs do |runtime, workspace|
      broken = Object.new
      broken.define_singleton_method(:call) { |*| raise Tamoz::Comms::TransientTransportError, 'boom' }

      status, _out, err = cli(runtime, %W[telegram setup --workspace #{workspace}], bot: broken)

      assert_equal 1, status
      assert_includes err, 'Telegram could not be reached'
    end
  end

  def test_start_names_a_revoked_bot_token
    with_dirs do |runtime, workspace|
      cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))

      status, _out, err = cli(runtime, %w[telegram start], bot: revoking_bot)

      assert_equal 1, status
      assert_includes err, 'refused the bot token'
    end
  end

  def test_missing_key_for_an_explicit_provider_names_the_env_var
    with_dirs do |runtime, workspace|
      cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))
      err = StringIO.new
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err:, input: StringIO.new, env: {},
                                  model_factory: ->(**) { credential_missing_client })

      chosen = cli.send(:working_provider, { runtime_dir: runtime, provider: 'deepseek' }, {})

      assert_nil chosen
      assert_includes err.string, 'no DEEPSEEK_API_KEY found'
    end
  end

  def test_runtime_path_falls_back_to_the_guide_directory
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

    assert_equal File.join(Dir.home, '.tamoz'), cli.send(:telegram_runtime_path, {})
  end

  def test_telegram_help_prints_usage_instead_of_an_invalid_argument
    with_dirs do |runtime, _workspace|
      status, out, _err = cli(runtime, %w[telegram --help], bot: Bot.new([]))

      assert_equal 0, status
      assert_includes out, 'Usage: tamoz telegram setup|start'
    end
  end

  # The global parser stops at `telegram`, so the flags must also be accepted after `start`.
  def test_start_accepts_provider_after_the_verb_and_runs
    with_dirs do |runtime, workspace|
      cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))
      captured = nil
      capture = lambda do |_directory, _surface, base|
        captured = base
        0
      end
      instance = start_instance(capture)
      status = instance.run(['--runtime-dir', runtime, 'telegram', 'start',
                             '--provider', 'deepseek', '--model', 'deepseek-chat'])

      assert_equal 0, status
      assert_equal 'deepseek', captured['TAMOZ_PROVIDER']
    end
  end

  def test_start_names_a_missing_env_file
    with_dirs do |runtime, workspace|
      status, _out, err = cli(runtime, %W[telegram start --env-file #{File.join(workspace, 'nope.env')}],
                              bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, 'cannot read --env-file'
    end
  end

  def test_start_names_a_missing_adapter
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {},
                                comms_client_factory: lambda { |_token|
                                  raise Tamoz::Agent::CLICommsShared::MissingAdapterError, 'no adapter'
                                })

    assert_equal 'no adapter', cli.send(:token_problem, { 'TAMOZ_TELEGRAM_BOT_TOKEN' => 'x' })
  end

  def test_setup_with_a_new_workspace_updates_the_root
    with_dirs do |runtime, workspace|
      other = File.join(File.dirname(workspace), 'other')
      FileUtils.mkdir_p(other)
      cli(runtime, %W[telegram setup --workspace #{workspace} --owner #{OWNER}], bot: Bot.new([]))

      status, out, err = cli(runtime, %W[telegram setup --workspace #{other} --owner #{OWNER}], bot: Bot.new([]))

      assert_equal 0, status, err
      assert_equal other, Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {}).workspace_root
      assert_includes out, other
    end
  end

  def test_setup_refuses_a_missing_workspace_without_writing_a_runtime
    with_dirs do |runtime, workspace|
      status, _out, err = cli(runtime, %W[telegram setup --workspace #{File.join(workspace, 'nope')} --owner #{OWNER}],
                              bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, 'workspace folder does not exist'
      refute_path_exists File.join(runtime, 'config.yaml')
    end
  end

  def test_stop_child_escalates_to_kill_a_child_that_ignores_term
    pid = Process.spawn('sh', '-c', 'trap "" TERM; sleep 30')
    sleep 0.2
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

    cli.send(:stop_child, pid, grace: 0.5)

    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  private

  def start_instance(on_run)
    instance = Tamoz::Agent::CLI.new(
      out: StringIO.new, err: StringIO.new, input: StringIO.new,
      env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:test' },
      comms_client_factory: ->(_token) { Bot.new([]) }, model_factory: ->(**) { ping_ok_client }
    )
    instance.define_singleton_method(:run_telegram) { |directory, surface, base| on_run.call(directory, surface, base) }
    instance
  end

  def ping_ok_client
    Object.new.tap do |client|
      client.define_singleton_method(:generate) { |**| 'ok' }
    end
  end

  def write_unpinned_channel(runtime)
    path = File.join(runtime, 'config.yaml')
    document = Psych.safe_load_file(path, aliases: false)
    document['channels'] = {
      'telegram-ghassan' => {
        'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'default',
        'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
        'expected_bot_id' => 0, 'admission' => { 'direct' => 'pairing' }
      }
    }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end

  def revoking_bot
    bot = Object.new
    bot.define_singleton_method(:origin) { 'https://api.telegram.org' }
    bot.define_singleton_method(:call) do |method, *|
      raise Tamoz::Comms::AuthenticationError, 'unauthorized' if method == 'getMe'

      { 'message_id' => 1, 'date' => 1 }
    end
    bot
  end

  def credential_missing_client
    Object.new.tap do |client|
      client.define_singleton_method(:generate) do |**|
        raise Tamoz::Agent::ModelCallError.new(code: 'credential_unavailable')
      end
    end
  end

  def with_dirs
    Dir.mktmpdir('tamoz-telegram-cli') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      yield File.join(root, 'runtime'), workspace
    end
  end

  def cli(runtime, argv, bot:, input: '', env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:test' })
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime] + argv, out:, err:, input: StringIO.new(input),
                                                                      env:, comms_client_factory: ->(_token) { bot })
    [status, out.string, err.string]
  end

  # The provider choice, without starting processes.
  def capture_start(runtime, factory, env)
    err = StringIO.new
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err:, input: StringIO.new, env:, model_factory: factory)
    chosen = cli.send(:working_provider, { runtime_dir: runtime }, env)
    [chosen, err.string]
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
