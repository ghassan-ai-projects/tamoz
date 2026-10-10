# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/loopback_channel'
require_relative 'support/loopback_pass'
require 'open3'
require 'tmpdir'

# The CLI reaches every channel through the registry: a new kind needs only its own code, an unknown kind is
# refused at every entry point, and a channel sees only the variables it declares.
class ChannelKindsTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  KEYS = { 'ZAI_API_KEY' => 'chat-key', 'LOOPBACK_TOKEN' => 'loop', 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:test' }.freeze

  # Answers the chat model's start probe.
  class Model
    def generate(**) = 'ok'
  end

  def with_runtime(kind = LoopbackChannel::Kind.new)
    Dir.mktmpdir('tamoz-channel-kinds') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      runtime = File.join(root, 'runtime')
      tamoz(runtime, 'setup', '--workspace', workspace, '--chat', 'zai/glm-5.3-flash')
      yield runtime, kind
    end
  end

  def tamoz(runtime, *argv, env: KEYS, kinds: LoopbackChannel.kinds)
    out = StringIO.new
    err = StringIO.new
    cli = Tamoz::Agent::CLI.new(out:, err:, input: StringIO.new, env:, channel_kinds: kinds,
                                model_factory: ->(**) { Model.new })
    cli.define_singleton_method(:serve) { |*| 0 }
    [cli.run(['--runtime-dir', runtime, *argv]), out.string, err.string]
  end

  def edit_channel(runtime, surface)
    path = File.join(runtime, RuntimeDirectory::CONFIG_FILE)
    document = Psych.safe_load_file(path)
    yield document.fetch('channels').fetch(surface)
    File.write(path, Psych.dump(document))
  end

  def test_a_new_kind_is_added_and_started_with_only_its_own_code
    with_runtime do |runtime, kind|
      status, out, err = tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))

      assert_equal 0, status, err
      assert_includes out, 'Loopback ready.'
      status, out, err = tamoz(runtime, 'start', kinds: LoopbackChannel.kinds(kind))

      assert_equal 0, status, err
      assert_includes out, 'Tamoz is starting loopback with zai/glm-5.3-flash.'
    end
  end

  def test_a_new_kind_admits_and_delivers_through_the_shared_gateway
    Dir.mktmpdir('tamoz-loopback') do |root|
      result = LoopbackPass.run(root)

      assert_equal [0, 0], result.values_at('admitted', 'delivered')
      assert_match(/\Aloopback\.loopback\.\h{16}\z/, result.fetch('threads').first)
      assert_equal ['hi back'], result.fetch('replies')
    end
  end

  def test_the_cli_and_core_run_a_new_kind_without_either_adapter_gem
    Dir.mktmpdir('tamoz-loopback') do |root|
      # A bare environment: an inherited bundle would read every gemspec, adapters' version files included.
      env = ENV.to_h.slice('PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'GEM_HOME', 'GEM_PATH')
      out, err, status = Open3.capture3(env, RbConfig.ruby, ROOT.join('test/support/loopback_pass.rb').to_s,
                                        ROOT.to_s, root, unsetenv_others: true)

      assert_predicate status, :success?, err
      result = JSON.parse(out.lines.last)

      assert_equal ['hi back'], result.fetch('replies')
      assert_empty result.fetch('adapters_loaded')
    end
  end

  def test_a_setup_sees_only_the_variables_it_declares
    with_runtime do |runtime, kind|
      tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))

      assert_equal({ 'LOOPBACK_TOKEN' => 'loop' }, kind.setup.seen_env)
      tamoz(runtime, 'start', kinds: LoopbackChannel.kinds(kind))

      assert_equal({ 'LOOPBACK_TOKEN' => 'loop' }, kind.setup.seen_env)
    end
  end

  def test_a_kind_the_registry_does_not_know_is_refused_everywhere
    with_runtime do |runtime, kind|
      tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))
      shipped = Tamoz::Agent::CHANNEL_KINDS

      assert_includes tamoz(runtime, 'start', kinds: shipped)[2], '"loopback" is not a channel kind'
      assert_includes tamoz(runtime, 'comms', 'serve', '--once', kinds: shipped)[2], '"loopback" is not a channel kind'
      assert_includes tamoz(runtime, 'comms', 'doctor', kinds: shipped)[1], '"loopback" is not a channel kind'
      assert_equal 64, tamoz(runtime, 'channel', 'add', 'loopback', kinds: shipped)[0]
    end
  end

  def test_a_credential_the_kind_does_not_declare_is_refused
    with_runtime do |runtime, kind|
      tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))
      edit_channel(runtime, 'loopback') { |entry| entry['credential_ref']['name'] = 'ZAI_API_KEY' }

      assert_includes tamoz(runtime, 'start', kinds: LoopbackChannel.kinds(kind))[2],
                      'credential_ref names ZAI_API_KEY, which a loopback channel does not hold'
    end
  end

  def test_a_talk_page_on_a_network_address_without_an_allowed_host_is_refused_by_serve
    with_runtime do |runtime|
      tamoz(runtime, 'channel', 'add', 'talk')
      edit_channel(runtime, 'talk') { |entry| entry['settings']['host'] = '0.0.0.0' }
      status, _out, err = tamoz(runtime, 'comms', 'serve', '--once')

      assert_equal 1, status
      assert_includes err, '--allow-host'
    end
  end

  def test_a_kinds_credential_is_its_own_token_not_another_declared_variable
    with_runtime do |runtime|
      tamoz(runtime, 'channel', 'add', 'talk')
      edit_channel(runtime, 'talk') { |entry| entry['credential_ref']['name'] = 'TAMOZ_TALK_TRACE' }

      assert_includes tamoz(runtime, 'comms', 'serve', '--once')[2], "a talk surface's credential is TAMOZ_TALK_TOKEN"
    end
  end

  def test_a_telegram_surface_cannot_speak
    with_runtime do |runtime|
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
      entry = { 'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'chat',
                'stream_id' => 'telegram:bot:7', 'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                'rendering' => { 'speech' => true } }

      error = assert_raises(Tamoz::Comms::ValidationError) do
        cli.send(:build_descriptor, 'telegram', entry, RuntimeDirectory.resolve(path: runtime, env: {}))
      end
      assert_includes error.message, 'cannot speak'
    end
  end

  def test_adding_any_channel_to_a_runtime_inside_the_workspace_is_refused
    Dir.mktmpdir('tamoz-channel-kinds') do |root|
      runtime = File.join(root, '.tamoz')
      tamoz(runtime, 'setup', '--workspace', root, '--chat', 'zai/glm-5.3-flash')
      status, _out, err = tamoz(runtime, 'channel', 'add', 'loopback')

      assert_equal 1, status
      assert_includes err, 'inside the workspace'
    end
  end

  def test_a_model_key_named_like_a_channel_variable_is_refused
    kind = LoopbackChannel::Kind.new
    kind.setup.define_singleton_method(:env_names) { %w[LOOPBACK_TOKEN ZAI_API_KEY] }
    Dir.mktmpdir('tamoz-channel-kinds') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      runtime = File.join(root, 'runtime')
      tamoz(runtime, 'setup', '--workspace', workspace, '--chat', 'zai/glm-5.3-flash')
      tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))

      assert_includes tamoz(runtime, 'start', kinds: LoopbackChannel.kinds(kind))[2],
                      "the chat model's key is named like a channel variable"
    end
  end

  def test_a_missing_adapter_is_named_at_every_entry_point
    with_runtime do |runtime, kind|
      tamoz(runtime, 'channel', 'add', 'loopback', kinds: LoopbackChannel.kinds(kind))
      missing = Tamoz::Agent::ChannelKind.new(name: 'loopback', library: 'tamoz/no_such_adapter',
                                              namespace: 'Tamoz::NoSuchAdapter')
      kinds = Tamoz::Agent::CHANNEL_KINDS.merge('loopback' => missing)
      message = 'the loopback channel (tamoz-no_such_adapter) is not installed'

      assert_includes tamoz(runtime, 'start', kinds:)[2], message
      assert_includes tamoz(runtime, 'comms', 'serve', '--once', kinds:)[2], message
      assert_includes tamoz(runtime, 'comms', 'doctor', kinds:)[1], message
      assert_includes tamoz(runtime, 'channel', 'add', 'loopback', kinds:)[2], message
    end
  end
end
