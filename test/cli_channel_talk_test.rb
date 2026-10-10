# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# `tamoz channel add talk` writes the talk channel and its private link on a runtime `tamoz setup` made.
class CliChannelTalkTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  TELEGRAM = { 'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'telegram',
               'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
               'expected_bot_id' => 7_000_000_001 }.freeze

  def with_runtime
    Dir.mktmpdir('tamoz-channel-talk') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      runtime = File.join(root, 'runtime')
      tamoz(runtime, 'setup', '--workspace', workspace)
      yield runtime
    end
  end

  def tamoz(runtime, *argv)
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime, *argv], out:, err:, input: StringIO.new, env: {})
    [status, out.string, err.string]
  end

  def add_talk(runtime, *) = tamoz(runtime, 'channel', 'add', 'talk', *)

  def channel(runtime) = Psych.safe_load_file(File.join(runtime, 'config.yaml')).dig('channels', 'talk')

  def token(runtime) = File.read(File.join(runtime, 'channels', 'talk', 'token'))

  def test_the_page_listens_on_the_default_port
    with_runtime do |runtime|
      status, = add_talk(runtime)

      assert_equal [0, 8787], [status, channel(runtime).dig('settings', 'port')]
    end
  end

  def test_the_listen_address_is_the_channels_own_setting
    with_runtime do |runtime|
      add_talk(runtime, '--host', '100.64.0.1', '--allow-host', 'mac.tail.ts.net')

      assert_equal '100.64.0.1', channel(runtime).dig('settings', 'host')
      assert_equal 0o700, File.stat(File.join(runtime, 'channels', 'talk')).mode & 0o777
    end
  end

  def test_an_allowed_host_is_kept_in_lower_case
    with_runtime do |runtime|
      add_talk(runtime, '--allow-host', 'Mac.tail.ts.net')

      assert_equal ['mac.tail.ts.net'], channel(runtime).dig('settings', 'allow_hosts')
    end
  end

  def test_the_page_has_one_user_whose_approvals_are_buttons
    with_runtime do |runtime|
      add_talk(runtime)

      assert_equal [['talk:user:1'], 'deny_only'],
                   [channel(runtime).dig('admission', 'correspondents'), channel(runtime).dig('approvals', 'mode')]
    end
  end

  def test_the_channel_serves_the_runtime_profile
    with_runtime do |runtime|
      add_talk(runtime)

      assert_equal 'chat', channel(runtime)['profile']
    end
  end

  def test_beside_telegram_it_serves_the_profile_telegram_already_serves
    with_runtime do |runtime|
      config = File.join(runtime, 'config.yaml')
      File.write(config, Psych.dump(Psych.safe_load_file(config).merge('channels' => { 'telegram' => TELEGRAM })))
      tamoz(runtime, 'setup')
      status, _out, err = add_talk(runtime)

      assert_equal 0, status, err
      assert_equal 'telegram', channel(runtime)['profile']
      assert_equal %w[talk telegram], Psych.safe_load_file(config)['channels'].keys.sort
    end
  end

  def test_a_channel_the_gateway_would_refuse_is_never_written
    with_runtime do |runtime|
      before = File.read(File.join(runtime, 'config.yaml'))
      status, _out, err = add_talk(runtime, '--port', '70000')

      assert_equal [1, before], [status, File.read(File.join(runtime, 'config.yaml'))]
      assert_includes err, 'needs a port'
    end
  end

  def test_the_token_is_private_and_never_printed
    with_runtime do |runtime|
      _status, out, = add_talk(runtime)

      assert_equal 0o600, File.stat(File.join(runtime, 'channels', 'talk', 'token')).mode & 0o777
      refute_includes out, token(runtime).strip
    end
  end

  def test_adding_it_again_unchanged_keeps_the_revision_and_the_token
    with_runtime do |runtime|
      add_talk(runtime)
      first = token(runtime)
      add_talk(runtime)

      assert_equal 1, channel(runtime)['revision']
      assert_equal first, token(runtime)
    end
  end

  def test_a_changed_port_bumps_the_revision
    with_runtime do |runtime|
      add_talk(runtime)
      add_talk(runtime, '--port', '8790')

      assert_equal 2, channel(runtime)['revision']
    end
  end

  def test_rotation_replaces_the_token_and_says_old_links_work_until_a_restart
    with_runtime do |runtime|
      add_talk(runtime)
      first = token(runtime)
      _status, out, = add_talk(runtime, '--rotate-token')

      refute_equal first, token(runtime)
      assert_includes out, 'until it is restarted'
    end
  end

  def test_a_damaged_token_is_replaced
    with_runtime do |runtime|
      add_talk(runtime)
      File.write(File.join(runtime, 'channels', 'talk', 'token'), "short\n")
      add_talk(runtime)

      assert_operator token(runtime).strip.length, :>=, 32
    end
  end

  def test_a_runtime_inside_the_workspace_is_refused_so_the_agent_cannot_read_the_token
    Dir.mktmpdir('tamoz-channel-talk') do |root|
      runtime = File.join(root, '.tamoz')
      tamoz(runtime, 'setup', '--workspace', root)
      status, _out, err = add_talk(runtime)

      assert_equal 1, status
      assert_includes err, "could read the channel's secrets"
      refute_path_exists File.join(runtime, 'channels', 'talk', 'token')
    end
  end
end
