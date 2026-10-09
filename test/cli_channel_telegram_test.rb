# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_cli_fixture'

# `tamoz channel add telegram` pairs a bot with its owner on a runtime `tamoz setup` made.
class CliChannelTelegramTest < Minitest::Test
  include TelegramCliFixture

  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  OTHER_BOT = BOT.merge('id' => 7_000_000_002, 'username' => 'other_bot')

  def private_message(from_id, name)
    { 'update_id' => 5, 'message' => { 'chat' => { 'id' => from_id, 'type' => 'private' },
                                       'from' => { 'id' => from_id, 'first_name' => name }, 'text' => '/start' } }
  end

  def channel(runtime, surface = 'telegram') = RuntimeDirectory.resolve(path: runtime, env: {}).channels.fetch(surface)

  def config_text(runtime) = File.read(File.join(runtime, 'config.yaml'))

  def backups(runtime) = Dir[File.join(runtime, "#{RuntimeDirectory::CONFIG_FILE}.bak-*")]

  def test_the_first_private_sender_the_operator_confirms_is_allowed
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      status, out, err = cli(runtime, %w[channel add telegram], bot: Bot.new([private_message(OWNER, 'G')]),
                                                                input: "y\n")

      assert_equal 0, status, err
      assert_includes out, 'Telegram is paired'
      assert_equal ["telegram:user:#{OWNER}"], channel(runtime).dig('admission', 'correspondents')
    end
  end

  def test_the_channel_is_pinned_to_the_bot
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)

      assert_equal BOT.fetch('id'), channel(runtime).fetch('expected_bot_id')
    end
  end

  def test_the_pairing_message_is_consumed_and_answered
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      bot = Bot.new([private_message(OWNER, 'G')])
      cli(runtime, %w[channel add telegram], bot:, input: "y\n")

      assert_includes bot.calls, ['getUpdates', { 'offset' => 6, 'timeout' => 0 }]
      assert(bot.calls.any? { |method, params| method == 'sendMessage' && params['chat_id'] == OWNER })
    end
  end

  def test_the_channel_serves_the_runtime_profile
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)

      assert_equal 'chat', channel(runtime).fetch('profile')
    end
  end

  def test_the_written_channel_passes_the_doctor
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)

      assert_equal 0, cli(runtime, %w[comms doctor], bot: Bot.new([]))[0]
    end
  end

  def test_a_sender_the_operator_rejects_is_not_paired
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      status, _out, err = cli(runtime, %w[channel add telegram], bot: Bot.new([private_message(42, 'Stranger')]),
                                                                 input: "n\n")

      assert_equal 1, status
      assert_includes err, 'not paired'
      assert_empty RuntimeDirectory.resolve(path: runtime, env: {}).channels
    end
  end

  def test_the_config_lands_privately_and_no_profile_is_written
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      writes = atomic_writes { cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([])) }

      assert_includes writes, [:replace, File.join(runtime, 'config.yaml'), 0o600]
      refute(writes.any? { |_operation, path, _mode| path.include?('/profiles/') })
    end
  end

  def test_an_operator_edit_to_the_profile_survives_pairing
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      profile = File.join(runtime, 'profiles', 'chat.yaml')
      File.write(profile, before = "#{File.read(profile)}# the operator's edit\n")
      cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))

      assert_equal before, File.read(profile)
    end
  end

  def test_pairing_the_same_owner_again_writes_nothing
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
      before = config_text(runtime)
      cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))

      assert_equal before, config_text(runtime)
    end
  end

  def test_pairing_another_person_keeps_the_people_already_allowed
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
      cli(runtime, %w[channel add telegram --owner 42], bot: Bot.new([]))

      assert_equal ["telegram:user:#{OWNER}", 'telegram:user:42'], channel(runtime).dig('admission', 'correspondents')
    end
  end

  def test_a_changed_channel_gets_the_next_revision
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
      cli(runtime, %w[channel add telegram --owner 42], bot: Bot.new([]))

      assert_equal 2, channel(runtime).fetch('revision')
    end
  end

  def test_a_second_bot_is_refused_and_the_first_kept
    with_dirs do |runtime, workspace|
      pair(runtime, workspace)
      before = config_text(runtime)
      other = Bot.new([])
      other.define_singleton_method(:call) { |method, *| method == 'getMe' ? OTHER_BOT : {} }
      status, _out, err = cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: other)

      assert_equal [1, before], [status, config_text(runtime)]
      assert_includes err, "already serves @#{BOT.fetch('username')}"
    end
  end

  def test_a_runtime_that_was_never_set_up_is_named_and_left_alone
    with_dirs do |runtime, _workspace|
      status, _out, err = cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))

      assert_includes err, "run 'tamoz setup' first"
      refute_path_exists runtime
      assert_equal 1, status
    end
  end

  def test_a_runtime_without_a_chat_profile_is_sent_to_setup
    with_dirs do |runtime, workspace|
      RuntimeDirectory.create!(runtime, workspace:)
      status, _out, err = cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))

      assert_equal 1, status
      assert_includes err, "no chat profile yet; run 'tamoz setup' first"
    end
  end

  # The owner's half-finished runtime: a channel with no bot id, whose profile `setup` then writes.
  def test_setup_then_pairing_repairs_an_unpinned_channel
    with_dirs do |runtime, workspace|
      RuntimeDirectory.create!(runtime, workspace:)
      write_unpinned_channel(runtime)
      set_up_runtime(runtime, workspace)
      status, _out, err = cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))

      assert_equal 0, status, err
      assert_equal [['telegram-ghassan'], BOT.fetch('id'), 'default'],
                   [RuntimeDirectory.resolve(path: runtime, env: {}).channels.keys,
                    *channel(runtime, 'telegram-ghassan').values_at('expected_bot_id', 'profile')]
    end
  end

  def test_without_a_token_it_says_where_the_token_comes_from
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      status, _out, err = cli(runtime, %w[channel add telegram], bot: Bot.new([]), env: {})

      assert_equal 1, status
      assert_includes err, '@BotFather'
    end
  end

  def test_the_token_can_come_from_an_env_file
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      env_file = File.join(workspace, '.env')
      File.write(env_file, "export TAMOZ_TELEGRAM_BOT_TOKEN='123:from-file'\n")
      status, _out, err = cli(runtime, %W[channel add telegram --owner #{OWNER} --env-file #{env_file}],
                              bot: Bot.new([]), env: {})

      assert_equal 0, status, err
    end
  end

  def test_a_transient_telegram_failure_is_named_without_a_backtrace
    with_dirs do |runtime, workspace|
      set_up_runtime(runtime, workspace)
      broken = Object.new
      broken.define_singleton_method(:call) { |*| raise Tamoz::Comms::TransientTransportError, 'boom' }
      status, _out, err = cli(runtime, %w[channel add telegram], bot: broken)

      assert_equal 1, status
      assert_includes err, 'Telegram could not be reached'
    end
  end

  def test_help_prints_the_options
    with_dirs do |runtime, _workspace|
      status, out, = cli(runtime, %w[channel add telegram --help], bot: Bot.new([]))

      assert_equal 0, status
      assert_includes out, '--owner'
    end
  end

  def test_channel_alone_prints_the_kinds
    with_dirs do |runtime, _workspace|
      status, out, = cli(runtime, %w[channel], bot: Bot.new([]))

      assert_equal 1, status
      assert_includes out, 'add talk'
    end
  end

  def test_an_unknown_channel_kind_is_a_usage_error
    with_dirs do |runtime, _workspace|
      status, _out, err = cli(runtime, %w[channel add slack], bot: Bot.new([]))

      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_includes err, 'tamoz channel add telegram|talk'
    end
  end

  private

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
  end
end
