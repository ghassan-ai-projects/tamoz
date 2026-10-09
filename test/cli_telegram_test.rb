# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'
require_relative 'support/telegram_cli_fixture'

# `tamoz telegram start` against a scripted Bot API client and scripted models.
class CliTelegramTest < Minitest::Test
  include TelegramCliFixture

  def test_start_skips_a_provider_that_refuses_and_names_why
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
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

      assert_includes err, 'deepseek/deepseek-chat (DEEPSEEK_API_KEY): the account is out of credit'
      assert_equal %w[openrouter deepseek/deepseek-v4.1-flash], out
    end
  end

  def test_start_before_setup_says_to_run_setup
    with_dirs do |runtime, workspace|
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace:)
      status, _out, err = cli(runtime, %w[telegram start], bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, 'tamoz channel add telegram'
    end
  end

  def test_start_names_a_revoked_bot_token
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)

      status, _out, err = cli(runtime, %w[telegram start], bot: revoking_bot)

      assert_equal 1, status
      assert_includes err, 'refused the bot token'
    end
  end

  def test_start_refuses_while_another_bot_holds_telegram
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
      hold_poller(runtime, owner: "gateway:#{Process.pid}")

      status, _out, err = cli(runtime, %w[telegram start], bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, "already running for this channel (pid #{Process.pid})"
    end
  end

  def hold_poller(runtime, owner:)
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
                     .send(:with_comms_runtime, { runtime_dir: runtime }) do |_directory, _adapter, store, _checkpoints|
      store.acquire_poller_lease(surface_id: 'telegram', bot_id: BOT.fetch('id'), owner:, fence: 1, ttl_s: 60,
                                 now: Time.now.utc)
    end
  end

  def test_missing_key_for_an_explicit_provider_names_the_env_var
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
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
      assert_includes out, 'Usage: tamoz telegram start'
    end
  end

  # The global parser stops at `telegram`, so the flags must also be accepted after `start`.
  def test_start_accepts_provider_after_the_verb_and_runs
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
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

  def test_stop_child_escalates_to_kill_a_child_that_ignores_term
    Dir.mktmpdir('tamoz-stop-child') do |directory|
      ready = File.join(directory, 'ready')
      pid = Process.spawn(
        RbConfig.ruby, '-e',
        "Signal.trap('TERM', 'IGNORE'); File.write(ARGV[0], 'ready'); sleep 30", ready
      )
      Timeout.timeout(10) { sleep 0.01 until File.file?(ready) }
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

      cli.send(:stop_child, pid, grace: 0.5)

      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
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

  # The provider choice, without starting processes.
  def capture_start(runtime, factory, env)
    err = StringIO.new
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err:, input: StringIO.new, env:, model_factory: factory)
    chosen = cli.send(:working_provider, { runtime_dir: runtime }, env)
    [chosen, err.string]
  end
end
