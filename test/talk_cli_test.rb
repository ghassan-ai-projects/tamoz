# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# `tamoz talk setup|start` with scripted models; nothing is spawned.
# rubocop:disable Minitest/MultipleAssertions
class TalkCliTest < Minitest::Test
  SPEECH = { 'TAMOZ_TRANSCRIPTION_PROVIDER' => 'openrouter', 'TAMOZ_TRANSCRIPTION_MODEL' => 'openai/gpt-4o-mini-transcribe',
             'TAMOZ_TRANSCRIPTION_CREDENTIAL' => 'OPENROUTER_SPEECH_API_KEY',
             'TAMOZ_VOICE_PROVIDER' => 'openrouter', 'TAMOZ_VOICE_MODEL' => 'hexgrad/kokoro-82m',
             'TAMOZ_VOICE_NAME' => 'af_heart', 'TAMOZ_VOICE_CREDENTIAL' => 'OPENROUTER_SPEECH_API_KEY',
             'OPENROUTER_SPEECH_API_KEY' => 'speech-key', 'DEEPSEEK_API_KEY' => 'chat-key' }.freeze

  def with_runtime
    Dir.mktmpdir('tamoz-talk-cli') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      yield File.join(root, 'runtime'), workspace
    end
  end

  def cli(env: SPEECH, roles: nil)
    out = StringIO.new
    err = StringIO.new
    instance = Tamoz::Agent::CLI.new(out:, err:, input: StringIO.new, env:,
                                     model_factory: lambda { |**|
                                       Object.new.tap do |m|
                                         m.define_singleton_method(:generate) do |**|
                                           'ok'
                                         end
                                       end
                                     })
    instance.instance_variable_set(:@talk_role_factory, roles || ->(_role) { speech_ok })
    [instance, out, err]
  end

  def speech_ok
    Object.new.tap do |model|
      model.define_singleton_method(:transcribe) { |**| :ok }
      model.define_singleton_method(:speak) { |**| :ok }
    end
  end

  def setup_talk(runtime, workspace, *extra, port: free_port)
    instance, out, err = cli
    extra = ['--port', port.to_s, *extra] if port && !extra.include?('--port')
    status = instance.run(['--runtime-dir', runtime, 'talk', 'setup', '--workspace', workspace, *extra])
    [status, out.string, err.string]
  end

  def free_port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }

  def talk_port(runtime)
    Psych.safe_load_file(File.join(runtime, Tamoz::Agent::RuntimeDirectory::CONFIG_FILE)).dig('channels', 'talk',
                                                                                              'talk', 'port')
  end

  def start(runtime, env: SPEECH, roles: nil, args: [])
    instance, out, err = cli(env:, roles:)
    spawned = nil
    instance.define_singleton_method(:run_talk) { |_directory, base| (spawned = base) && 0 }
    status = instance.run(['--runtime-dir', runtime, 'talk', 'start', '--provider', 'deepseek',
                           '--model', 'deepseek-chat', *args])
    [status, out.string, err.string, spawned]
  end

  def test_setup_writes_the_channel_profile_and_a_private_token
    with_runtime do |runtime, workspace|
      status, out, = setup_talk(runtime, workspace, '--allow-host', 'Mac.tail.ts.net', port: nil)
      config = Psych.safe_load_file(File.join(runtime, 'config.yaml'))
      channel = config.dig('channels', 'talk')
      token = File.join(runtime, 'talk', 'token')

      assert_equal 0, status
      assert_equal ['talk', 1, 8787, ['mac.tail.ts.net'], ['talk:user:1'], 'deny_only'],
                   [channel['kind'], channel['revision'], channel.dig('talk', 'port'), channel.dig('talk', 'allow_hosts'),
                    channel.dig('admission', 'correspondents'), channel.dig('approvals', 'mode')]
      assert_equal 0o600, File.stat(token).mode & 0o777
      assert_path_exists File.join(runtime, 'profiles', 'talk.yaml')
      refute_includes out, File.read(token).strip, 'setup never prints the token'
    end
  end

  def test_a_second_setup_bumps_the_revision_keeps_the_token_and_rotation_replaces_it
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace, port: nil)
      first = File.read(File.join(runtime, 'talk', 'token'))
      setup_talk(runtime, workspace, '--port', '8790')
      kept = File.read(File.join(runtime, 'talk', 'token'))
      setup_talk(runtime, workspace, '--rotate-token', port: nil)
      channel = Psych.safe_load_file(File.join(runtime, 'config.yaml')).dig('channels', 'talk')

      assert_equal first, kept
      refute_equal first, File.read(File.join(runtime, 'talk', 'token'))
      assert_equal [3, 8790], [channel['revision'], channel.dig('talk', 'port')]
    end
  end

  def test_start_prints_the_link_once_and_hands_the_token_to_the_gateway_only
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      status, out, _err, spawned = start(runtime)
      token = File.read(File.join(runtime, 'talk', 'token')).strip

      assert_equal 0, status
      assert_includes out, "http://127.0.0.1:#{talk_port(runtime)}/#token=#{token}"
      assert_includes out, 'approve its changes'
      gateway = Tamoz::Agent::ChildEnvironments.gateway_env(spawned, runtime_dir: runtime, surface: 'talk',
                                                                     kind: 'talk')
      worker = Tamoz::Agent::ChildEnvironments.worker_env(spawned, runtime_dir: runtime)

      assert_equal token, gateway.fetch('TAMOZ_TALK_TOKEN')
      assert_equal 'speech-key', gateway.fetch('OPENROUTER_SPEECH_API_KEY')
      assert_equal %w[TAMOZ_RUNTIME_DIR TAMOZ_TALK_HOST TAMOZ_TALK_TOKEN TAMOZ_VOICE_CREDENTIAL TAMOZ_VOICE_MODEL
                      TAMOZ_VOICE_NAME TAMOZ_VOICE_PROVIDER OPENROUTER_SPEECH_API_KEY].sort,
                   (gateway.keys - Tamoz::Agent::ChildEnvironments::STANDARD).sort
      refute gateway.key?('DEEPSEEK_API_KEY'), 'the gateway never holds the chat key'
      refute worker.key?('TAMOZ_TALK_TOKEN'), 'the worker never holds the access token'
    end
  end

  def test_start_refuses_the_chat_key_as_the_voice_key_by_name_or_by_value
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      [SPEECH.merge('TAMOZ_VOICE_CREDENTIAL' => 'DEEPSEEK_API_KEY'),
       SPEECH.merge('TAMOZ_VOICE_CREDENTIAL' => 'MY_COPY_API_KEY', 'MY_COPY_API_KEY' => 'chat-key')].each do |env|
        status, _out, err, spawned = start(runtime, env:)

        assert_equal 1, status
        assert_includes err, "must not be the chat model's key"
        assert_nil spawned
      end
    end
  end

  def test_start_refuses_a_damaged_token_and_a_taken_port_before_printing_the_link
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      taken = TCPServer.new('127.0.0.1', talk_port(runtime))
      status, out, err, spawned = start(runtime)

      assert_equal 1, status
      assert_includes err, "cannot listen on 127.0.0.1:#{talk_port(runtime)}"
      refute_includes out, '#token='
      assert_nil spawned
      taken.close
      File.write(File.join(runtime, 'talk', 'token'), "short\n")
      status, _out, err, = start(runtime)

      assert_equal 1, status
      assert_includes err, '--rotate-token'
    ensure
      taken&.close unless taken&.closed?
    end
  end

  def test_start_names_a_missing_or_failing_speech_role
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      _, _, missing, = start(runtime, env: SPEECH.except('TAMOZ_TRANSCRIPTION_PROVIDER'), roles: ->(_role) {})
      failing = lambda do |role|
        Object.new.tap do |model|
          model.define_singleton_method(:transcribe) { |**| :ok }
          if role == 'VOICE'
            model.define_singleton_method(:speak) do |**|
              raise Tamoz::Agent::ModelCallError.new(code: 'http_failure')
            end
          end
          model.define_singleton_method(:speak) { |**| :ok } unless role == 'VOICE'
        end
      end
      status, _, voice, spawned = start(runtime, roles: failing)

      assert_includes missing, 'TAMOZ_TRANSCRIPTION_PROVIDER'
      assert_equal 1, status
      assert_includes voice, 'the voice model did not answer'
      assert_nil spawned
    end
  end

  def test_a_network_address_needs_an_allowed_host_and_warns
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      status, _, err, = start(runtime, args: %w[--host 0.0.0.0])

      assert_equal 1, status
      assert_includes err, '--allow-host'
      setup_talk(runtime, workspace, '--allow-host', 'mac.tail.ts.net')
      status, out, err, = start(runtime, args: %w[--host 0.0.0.0])

      assert_equal 0, status
      assert_includes err, 'clear text'
      assert_includes out, 'https://mac.tail.ts.net/#token='
    end
  end

  def test_a_second_start_is_refused_while_a_gateway_holds_the_channel
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      hold_poller(runtime, owner: "gateway:#{Process.pid}")
      status, _, err, spawned = start(runtime)

      assert_equal 1, status
      assert_includes err, "already running for this channel (pid #{Process.pid})"
      assert_nil spawned
    end
  end

  def test_a_taken_port_is_named_by_serve_and_by_doctor
    with_runtime do |runtime, workspace|
      port = free_port
      setup_talk(runtime, workspace, '--port', port.to_s)
      taken = TCPServer.new('127.0.0.1', port)
      env = SPEECH.merge('TAMOZ_TALK_TOKEN' => 'a' * 43)
      instance, _out, err = cli(env:)
      status = instance.run(['--runtime-dir', runtime, 'comms', 'serve', '--surface', 'talk'])

      assert_equal 1, status
      assert_includes err.string, 'the talk page could not listen (EADDRINUSE)'
      instance, out, = cli(env:)

      assert_equal 1, instance.run(['--runtime-dir', runtime, 'comms', 'doctor'])
      assert_includes out.string, "the talk page cannot listen on 127.0.0.1:#{port}"
    ensure
      taken&.close
    end
  end

  def hold_poller(runtime, owner:)
    bot_id = Psych.safe_load_file(File.join(runtime, Tamoz::Agent::RuntimeDirectory::CONFIG_FILE))
                  .dig('channels', 'talk', 'expected_bot_id')
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
                     .send(:with_comms_runtime, { runtime_dir: runtime }) do |_directory, _adapter, store, _checkpoints|
      store.acquire_poller_lease(surface_id: 'talk', bot_id:, owner:, fence: 1, ttl_s: 60, now: Time.now.utc)
    end
  end

  def test_a_workspace_holding_the_runtime_is_refused_so_the_agent_cannot_read_the_token
    Dir.mktmpdir('tamoz-talk-cli') do |root|
      status, _out, err = setup_talk(File.join(root, '.tamoz'), root)

      assert_equal 1, status
      assert_includes err, 'could read the talk token'
      refute_path_exists File.join(root, '.tamoz', 'talk', 'token')
    end
  end

  def test_start_checks_a_speech_role_the_runtime_config_names
    with_runtime do |runtime, workspace|
      setup_talk(runtime, workspace)
      config = File.join(runtime, 'config.yaml')
      transcription = { 'provider' => 'openai', 'model' => 'whisper-1', 'api_base' => 'http://127.0.0.1:9/v1' }
      File.write(config,
                 Psych.dump(Psych.safe_load_file(config).merge('models' => { 'transcription' => transcription })))
      env = SPEECH.except('TAMOZ_TRANSCRIPTION_PROVIDER').merge('OPENAI_API_KEY' => 'k')
      _status, _out, err, = start(runtime, env:, roles: ->(_role) {})

      assert_includes err, 'the speech-to-text model did not answer'
    end
  end

  def test_start_before_setup_says_to_run_setup
    with_runtime do |runtime, _workspace|
      status, _, err, = start(runtime)

      assert_equal 1, status
      assert_includes err, 'tamoz talk setup'
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
