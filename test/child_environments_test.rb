# frozen_string_literal: true

require_relative 'test_helper'

# C7 (PLAN_ADR049 Phase 6) — exact per-command child environments: every
# child carries the standard runtime allowlist plus only its own credentials.
# The gateway never sees the model key, the worker never sees the bot token,
# queue/status see neither, and the harness sees only sanitized pointers.
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
