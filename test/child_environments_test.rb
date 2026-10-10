# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# Each child gets exactly its keys, composed from the runtime config and never from a shared environment.
class ChildEnvironmentsTest < Minitest::Test
  ChildEnvironments = Tamoz::Agent::ChildEnvironments
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory

  ENV_FILE = {
    'PATH' => '/usr/bin', 'HOME' => '/home/ops', 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8',
    'TMPDIR' => '/tmp', 'GEM_HOME' => '/gems', 'GEM_PATH' => '/gems', 'RUBYLIB' => '/lib',
    'ZAI_API_KEY' => 'chat-secret', 'ZAI_API_BASE' => 'https://api.z.ai/api/coding/paas/v4',
    'OPENROUTER_SPEECH_API_KEY' => 'speech-secret', 'OPENAI_API_KEY' => 'vision-secret',
    'TAMOZ_BRAVE_API_KEY' => 'search-secret', 'TAMOZ_WEBSEARCH_REGION' => 'gb',
    'TAMOZ_TELEGRAM_BOT_TOKEN' => 'bot-secret', 'TAMOZ_TALK_TOKEN' => 'talk-secret', 'FUTURE_CHANNEL_API_KEY' => 'later',
    'TAMOZ_ENV_FILE' => '/srv/.env', 'AWS_SECRET_ACCESS_KEY' => 'unrelated-secret'
  }.freeze
  SPEECH = { 'provider' => 'openrouter', 'credential' => 'OPENROUTER_SPEECH_API_KEY' }.freeze
  MODELS = { 'chat' => { 'provider' => 'zai', 'model' => 'glm-5.3-flash' },
             'transcription' => SPEECH.merge('model' => 'openai/gpt-4o-mini-transcribe'),
             'voice' => SPEECH.merge('model' => 'hexgrad/kokoro-82m', 'voice' => 'af_heart'),
             'vision' => { 'provider' => 'openai', 'model' => 'gpt-4o-mini' } }.freeze
  SOURCES = { 'websearch' => { 'enabled' => true, 'command' => '/opt/websearch',
                               'credential_refs' => %w[TAMOZ_BRAVE_API_KEY TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_ENV_FILE
                                                       TAMOZ_RUNTIME_DIR],
                               'env_allowlist' => %w[PATH TAMOZ_WEBSEARCH_REGION] } }.freeze

  TOKENS = { 'telegram' => 'TAMOZ_TELEGRAM_BOT_TOKEN', 'talk' => 'TAMOZ_TALK_TOKEN' }.freeze
  TELEGRAM = %w[TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_TELEGRAM_API_ORIGIN].freeze
  TALK = %w[TAMOZ_TALK_TOKEN TAMOZ_TALK_TRACE].freeze
  # Every registry kind's names, including one no runtime has configured yet.
  CHANNEL_NAMES = (TELEGRAM + TALK + %w[FUTURE_CHANNEL_API_KEY]).freeze

  def channel(kind, bot_id, **extra)
    { 'kind' => kind, 'revision' => 1, 'enabled' => true, 'profile' => 'chat', 'expected_bot_id' => bot_id,
      'credential_ref' => { 'kind' => 'env', 'name' => TOKENS.fetch(kind) },
      **extra }
  end

  def with_directory(models: MODELS)
    Dir.mktmpdir('tamoz-child-env') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      path = RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:, models:).path
      config = File.join(path, RuntimeDirectory::CONFIG_FILE)
      channels = { 'telegram' => channel('telegram', 7_000_000_001),
                   'talk' => channel('talk', 123_456_789_012, 'settings' => { 'port' => 8787 }) }
      File.write(config, Psych.dump(Psych.safe_load_file(config).merge('sources' => SOURCES, 'channels' => channels)))
      yield RuntimeDirectory.resolve(path:, env: {})
    end
  end

  def own_keys(env) = (env.keys - ChildEnvironments::STANDARD).sort

  def worker_env(directory,
                 base = ENV_FILE)
    ChildEnvironments.worker_env(base, directory:, channel_names: CHANNEL_NAMES)
  end

  def test_the_worker_holds_its_models_and_sources_keys_and_nothing_else
    with_directory do |directory|
      assert_equal %w[OPENAI_API_KEY OPENROUTER_SPEECH_API_KEY TAMOZ_BRAVE_API_KEY TAMOZ_RUNTIME_DIR
                      TAMOZ_WEBSEARCH_REGION ZAI_API_BASE ZAI_API_KEY], own_keys(worker_env(directory))
    end
  end

  def test_a_source_that_names_a_channel_token_does_not_get_it
    with_directory do |directory|
      refute worker_env(directory).key?('TAMOZ_TELEGRAM_BOT_TOKEN')
    end
  end

  def test_no_channel_variable_reaches_the_worker_even_one_a_model_key_is_named_after
    models = MODELS.merge('vision' => { 'provider' => 'openai', 'model' => 'gpt-4o-mini',
                                        'credential' => 'FUTURE_CHANNEL_API_KEY' })

    with_directory(models:) do |directory|
      assert_empty worker_env(directory).keys & CHANNEL_NAMES
    end
  end

  def test_a_source_cannot_override_the_runtime_or_reach_the_env_file
    with_directory do |directory|
      env = worker_env(directory, ENV_FILE.merge('TAMOZ_RUNTIME_DIR' => '/elsewhere'))

      assert_equal [directory.path, false], [env['TAMOZ_RUNTIME_DIR'], env.key?('TAMOZ_ENV_FILE')]
    end
  end

  def gateway_env(directory, vars, allowed, speech: false)
    ChildEnvironments.gateway_env(ENV_FILE, directory:, vars:, allowed:, speech:)
  end

  def test_the_telegram_gateway_holds_only_its_bot_token
    with_directory do |directory|
      env = gateway_env(directory, ENV_FILE.slice(*TELEGRAM), TELEGRAM)

      assert_equal %w[TAMOZ_RUNTIME_DIR TAMOZ_TELEGRAM_BOT_TOKEN], own_keys(env)
    end
  end

  def test_a_speaking_gateway_holds_its_token_and_the_voice_key_never_the_chat_key
    with_directory do |directory|
      env = gateway_env(directory, ENV_FILE.slice(*TALK), TALK, speech: true)

      assert_equal %w[OPENROUTER_SPEECH_API_KEY TAMOZ_RUNTIME_DIR TAMOZ_TALK_TOKEN], own_keys(env)
    end
  end

  def test_a_gateway_variable_its_kind_does_not_declare_is_refused
    with_directory do |directory|
      vars = ENV_FILE.slice(*TELEGRAM, 'AWS_SECRET_ACCESS_KEY')
      error = assert_raises(ChildEnvironments::Error) { gateway_env(directory, vars, TELEGRAM) }

      assert_includes error.message, 'AWS_SECRET_ACCESS_KEY'
    end
  end

  def test_a_model_key_is_refused_even_when_a_kind_declares_it
    with_directory do |directory|
      assert_raises(ChildEnvironments::Error) do
        gateway_env(directory, ENV_FILE.slice('ZAI_API_KEY'), TELEGRAM + %w[ZAI_API_KEY])
      end
    end
  end

  def test_a_role_without_its_own_key_uses_its_provider_variable
    with_directory(models: MODELS.merge('transcription' => { 'provider' => 'openai', 'model' => 'whisper-1' })) do |dir|
      assert_equal 'vision-secret', worker_env(dir).fetch('OPENAI_API_KEY')
    end
  end

  def test_queue_and_status_see_no_credential
    assert_equal %w[TAMOZ_RUNTIME_DIR], own_keys(ChildEnvironments.queue_status_env(ENV_FILE, runtime_dir: '/r'))
  end

  def test_the_harness_gets_only_sanitized_pointers
    env = ChildEnvironments.harness_env(ENV_FILE, runtime_dir: '/r', database_path: '/r/runtime.sqlite3')

    assert_equal %w[TAMOZ_DATABASE_PATH TAMOZ_RUNTIME_DIR], own_keys(env)
  end

  def test_every_child_carries_the_standard_runtime_allowlist
    env = ChildEnvironments.queue_status_env(ENV_FILE, runtime_dir: '/r')

    assert_equal ChildEnvironments::STANDARD.sort, (env.keys & ChildEnvironments::STANDARD).sort
  end
end
