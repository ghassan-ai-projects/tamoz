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
    'TAMOZ_TELEGRAM_BOT_TOKEN' => 'bot-secret', 'TAMOZ_TALK_TOKEN' => 'talk-secret', 'TAMOZ_TALK_HOST' => '127.0.0.1',
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
                   'talk' => channel('talk', 123_456_789_012, 'talk' => { 'port' => 8787 }) }
      File.write(config, Psych.dump(Psych.safe_load_file(config).merge('sources' => SOURCES, 'channels' => channels)))
      yield RuntimeDirectory.resolve(path:, env: {})
    end
  end

  def own_keys(env) = (env.keys - ChildEnvironments::STANDARD).sort

  def test_the_worker_holds_its_models_and_sources_keys_and_nothing_else
    with_directory do |directory|
      env = ChildEnvironments.worker_env(ENV_FILE, directory:)

      assert_equal %w[OPENAI_API_KEY OPENROUTER_SPEECH_API_KEY TAMOZ_BRAVE_API_KEY TAMOZ_RUNTIME_DIR
                      TAMOZ_WEBSEARCH_REGION ZAI_API_BASE ZAI_API_KEY], own_keys(env)
    end
  end

  def test_a_source_that_names_a_channel_token_does_not_get_it
    with_directory do |directory|
      refute ChildEnvironments.worker_env(ENV_FILE, directory:).key?('TAMOZ_TELEGRAM_BOT_TOKEN')
    end
  end

  def test_a_source_cannot_override_the_runtime_or_reach_the_env_file
    with_directory do |directory|
      env = ChildEnvironments.worker_env(ENV_FILE.merge('TAMOZ_RUNTIME_DIR' => '/elsewhere'), directory:)

      assert_equal [directory.path, false], [env['TAMOZ_RUNTIME_DIR'], env.key?('TAMOZ_ENV_FILE')]
    end
  end

  def test_the_telegram_gateway_holds_only_its_bot_token
    with_directory do |directory|
      env = ChildEnvironments.gateway_env(ENV_FILE, directory:, surface: 'telegram')

      assert_equal %w[TAMOZ_RUNTIME_DIR TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_TELEGRAM_SURFACE], own_keys(env)
    end
  end

  def test_the_talk_gateway_holds_its_token_and_the_voice_key_never_the_chat_key
    with_directory do |directory|
      env = ChildEnvironments.gateway_env(ENV_FILE, directory:, surface: 'talk')

      assert_equal %w[OPENROUTER_SPEECH_API_KEY TAMOZ_RUNTIME_DIR TAMOZ_TALK_HOST TAMOZ_TALK_TOKEN], own_keys(env)
    end
  end

  def test_a_role_without_its_own_key_uses_its_provider_variable
    with_directory(models: MODELS.merge('transcription' => { 'provider' => 'openai', 'model' => 'whisper-1' })) do |dir|
      assert_equal 'vision-secret', ChildEnvironments.worker_env(ENV_FILE, directory: dir).fetch('OPENAI_API_KEY')
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
