# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions
class ChildEnvironmentsTest < Minitest::Test
  ChildEnvironments = Tamoz::Agent::ChildEnvironments

  BASE = {
    'PATH' => '/usr/bin', 'HOME' => '/home/ops', 'LANG' => 'en_US.UTF-8',
    'TMPDIR' => '/tmp', 'GEM_HOME' => '/gems', 'GEM_PATH' => '/gems',
    'RUBYLIB' => '/lib', 'LC_ALL' => 'en_US.UTF-8',
    'TAMOZ_TELEGRAM_BOT_TOKEN' => 'bot-secret',
    'DEEPSEEK_API_KEY' => 'model-secret',
    'TAMOZ_ALMS_MCP_ENDPOINT' => 'http://alms.internal',
    'TAMOZ_PROVIDER' => 'deepseek', 'TAMOZ_MODEL' => 'deepseek-chat',
    'TAMOZ_RUNTIME_DIR' => '/srv/runtime', 'TAMOZ_TELEGRAM_SURFACE' => 'telegram-ops',
    'TAMOZ_ENV_FILE' => '/srv/.env', 'AWS_SECRET_ACCESS_KEY' => 'unrelated-secret'
  }.freeze

  def test_the_gateway_gets_the_bot_token_and_no_model_key
    env = ChildEnvironments.gateway_env(BASE, runtime_dir: '/srv/runtime', surface: 'telegram-ops')

    assert_equal 'bot-secret', env.fetch('TAMOZ_TELEGRAM_BOT_TOKEN')
    assert_equal 'telegram-ops', env.fetch('TAMOZ_TELEGRAM_SURFACE')
    refute env.key?('DEEPSEEK_API_KEY'), 'the gateway must not carry the model credential'
    refute env.key?('TAMOZ_ALMS_MCP_ENDPOINT'), 'the gateway must not carry the ALMS endpoint'
  end

  def test_the_worker_gets_the_model_key_and_no_bot_token
    env = ChildEnvironments.worker_env(BASE, runtime_dir: '/srv/runtime')

    assert_equal 'model-secret', env.fetch('DEEPSEEK_API_KEY')
    assert_equal 'deepseek', env.fetch('TAMOZ_PROVIDER')
    assert_equal 'deepseek-chat', env.fetch('TAMOZ_MODEL')
    refute env.key?('TAMOZ_TELEGRAM_BOT_TOKEN'), 'the worker must not carry the bot token'
    refute env.key?('TAMOZ_ALMS_MCP_ENDPOINT'),
           'the worker resolves the ALMS endpoint from the MCP config, not the environment'
  end

  def test_the_worker_gets_the_transcription_model_only_when_one_is_configured
    configured = BASE.merge('TAMOZ_TRANSCRIPTION_PROVIDER' => 'openai', 'TAMOZ_TRANSCRIPTION_MODEL' => 'whisper-1',
                            'OPENAI_API_KEY' => 'stt-secret')
    env = ChildEnvironments.worker_env(configured, runtime_dir: '/srv/runtime')

    assert_equal %w[openai whisper-1 stt-secret],
                 env.values_at('TAMOZ_TRANSCRIPTION_PROVIDER', 'TAMOZ_TRANSCRIPTION_MODEL', 'OPENAI_API_KEY')
    refute env.key?('TAMOZ_TELEGRAM_BOT_TOKEN')
    refute ChildEnvironments.worker_env(BASE.merge('OPENAI_API_KEY' => 'x'), runtime_dir: 'r').key?('OPENAI_API_KEY'),
           'no transcription model, no second key'
  end

  def test_a_role_reads_its_key_from_the_variable_it_names
    configured = BASE.merge('TAMOZ_TRANSCRIPTION_PROVIDER' => 'openrouter',
                            'TAMOZ_TRANSCRIPTION_MODEL' => 'openai/gpt-4o-mini-transcribe',
                            'TAMOZ_TRANSCRIPTION_CREDENTIAL' => 'OPENROUTER_SPEECH_API_KEY',
                            'OPENROUTER_SPEECH_API_KEY' => 'speech-secret', 'OPENROUTER_API_KEY' => 'chat-secret')
    env = ChildEnvironments.worker_env(configured, runtime_dir: 'r')

    assert_equal %w[OPENROUTER_SPEECH_API_KEY speech-secret],
                 env.values_at('TAMOZ_TRANSCRIPTION_CREDENTIAL', 'OPENROUTER_SPEECH_API_KEY')
    refute env.key?('OPENROUTER_API_KEY'), 'a role naming its key gets that key, not the provider default'
  end

  def test_a_role_may_not_name_a_channel_secret_or_a_runtime_variable
    %w[TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_ENV_FILE PATH TAMOZ_TALK_TOKEN].each do |name|
      configured = BASE.merge('TAMOZ_TRANSCRIPTION_PROVIDER' => 'openai', 'TAMOZ_TRANSCRIPTION_MODEL' => 'whisper-1',
                              'TAMOZ_TRANSCRIPTION_CREDENTIAL' => name)

      assert_raises(ArgumentError, name) { ChildEnvironments.worker_env(configured, runtime_dir: 'r') }
    end
  end

  def test_the_image_model_and_its_key_reach_only_the_worker
    configured = BASE.merge('TAMOZ_VISION_PROVIDER' => 'openai', 'TAMOZ_VISION_MODEL' => 'gpt-4o-mini',
                            'OPENAI_API_KEY' => 'vision-secret', 'TAMOZ_TELEGRAM_BOT_TOKEN' => 'bot')

    assert_equal %w[openai gpt-4o-mini vision-secret],
                 ChildEnvironments.worker_env(configured, runtime_dir: 'r')
                                  .values_at('TAMOZ_VISION_PROVIDER', 'TAMOZ_VISION_MODEL', 'OPENAI_API_KEY')
    refute ChildEnvironments.gateway_env(configured, runtime_dir: 'r', surface: 's').key?('OPENAI_API_KEY')
  end

  def test_queue_and_status_see_neither_credential
    env = ChildEnvironments.queue_status_env(BASE, runtime_dir: '/srv/runtime')

    assert_equal '/srv/runtime', env.fetch('TAMOZ_RUNTIME_DIR')
    refute env.key?('TAMOZ_TELEGRAM_BOT_TOKEN')
    refute env.key?('DEEPSEEK_API_KEY')
  end

  def test_the_harness_gets_only_sanitized_pointers
    env = ChildEnvironments.harness_env(BASE, runtime_dir: '/srv/runtime',
                                              database_path: '/srv/runtime/runtime.sqlite3')

    assert_equal '/srv/runtime', env.fetch('TAMOZ_RUNTIME_DIR')
    assert_equal '/srv/runtime/runtime.sqlite3', env.fetch('TAMOZ_DATABASE_PATH')
    refute env.key?('TAMOZ_ENV_FILE'), 'the harness must not pass the env-file path'
    refute env.key?('TAMOZ_TELEGRAM_BOT_TOKEN')
    refute env.key?('DEEPSEEK_API_KEY')
  end

  def test_no_map_ever_leaks_unrelated_credentials
    [ChildEnvironments.gateway_env(BASE, runtime_dir: 'r', surface: 's'),
     ChildEnvironments.worker_env(BASE, runtime_dir: 'r'),
     ChildEnvironments.queue_status_env(BASE, runtime_dir: 'r'),
     ChildEnvironments.harness_env(BASE, runtime_dir: 'r')].each do |env|
      refute env.key?('AWS_SECRET_ACCESS_KEY'),
             'an unrelated credential must never reach any child'
      refute env.key?('TAMOZ_ENV_FILE'), 'the env-file path must never reach any child'
    end
  end

  def test_every_child_carries_the_standard_runtime_allowlist
    env = ChildEnvironments.queue_status_env(BASE, runtime_dir: '/srv/runtime')

    assert_equal %w[GEM_HOME GEM_PATH HOME LANG LC_ALL PATH RUBYLIB TMPDIR],
                 env.keys.grep(/^(PATH|HOME|LANG|LC_ALL|TMPDIR|GEM_|RUBYLIB)/).sort
  end
end
# rubocop:enable Minitest/MultipleAssertions
