# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/runtime_models_fixture'
require 'tmpdir'

# Commands on a runtime take the chat model and the model roles from its config.
class CLIRuntimeModelsTest < Minitest::Test
  include RuntimeModelsFixture

  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  CHAT = { 'chat' => { 'provider' => 'zai', 'model' => 'glm-5.3-flash' } }.freeze
  SPEECH = { 'provider' => 'openrouter', 'model' => 'openai/gpt-4o-mini-transcribe',
             'credential' => 'OPENROUTER_SPEECH_API_KEY', 'api_base' => 'http://127.0.0.1:9/v1' }.freeze

  def with_runtime(models, &) = Dir.mktmpdir('tamoz-models') { |root| yield runtime_with_models(root, models) }

  def builder(env = {}) = Tamoz::Agent::CLI::ModelBuilder.new(env: { 'ZAI_API_KEY' => 'k' }.merge(env))

  def attachment_for(role, path, env = {})
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env:)
    cli.send(:attachment_model, role, runtime: RuntimeDirectory.resolve(path:, env: {}))
  end

  def pair(model) = [model.provider, model.model]

  def test_a_bad_models_section_is_refused_when_the_runtime_loads
    with_runtime('chat' => 'zai') do |path|
      error = assert_raises(RuntimeDirectory::Error) { RuntimeDirectory.resolve(path:, env: {}) }

      assert_match(/models\.chat must be a mapping/, error.message)
    end
  end

  def test_the_chat_model_comes_from_the_runtime_given_by_flag_or_variable
    with_runtime(CHAT) do |path|
      by_flag = builder.build({ runtime_dir: path })
      by_variable = builder('TAMOZ_RUNTIME_DIR' => path).build({})

      assert_equal [%w[zai glm-5.3-flash]] * 2, [pair(by_flag), pair(by_variable)]
    end
  end

  def test_a_provider_and_model_named_together_run_instead_of_the_runtime_model
    with_runtime(CHAT) do |path|
      flagged = builder('DEEPSEEK_API_KEY' => 'd').build({ runtime_dir: path, provider: 'deepseek',
                                                           model: 'deepseek-chat' })

      assert_equal %w[deepseek deepseek-chat], pair(flagged)
    end
  end

  def test_naming_only_the_model_over_a_runtime_model_is_refused
    with_runtime(CHAT) do |path|
      error = assert_raises(OptionParser::MissingArgument) { builder.build({ runtime_dir: path, model: 'gpt-4o' }) }

      assert_match(/--provider and --model together/, error.message)
    end
  end

  def test_naming_only_the_provider_over_a_runtime_model_is_refused
    with_runtime(CHAT) do |path|
      error = assert_raises(OptionParser::MissingArgument) do
        builder.build({ runtime_dir: path, provider: 'deepseek' })
      end

      assert_match(/--provider and --model together/, error.message)
    end
  end

  def test_an_empty_flag_does_not_hide_the_runtime_model
    with_runtime(CHAT) do |path|
      built = builder.build({ runtime_dir: path, model: '', provider: '' })

      assert_equal %w[zai glm-5.3-flash], pair(built)
    end
  end

  def test_a_running_process_keeps_the_runtime_model_it_read_first
    with_runtime(CHAT) do |path|
      models = builder
      first = models.build({ runtime_dir: path })
      write_models(path, 'chat' => { 'provider' => 'zai', 'model' => 'glm-4.6' })

      assert_equal pair(first), pair(models.build({ runtime_dir: path }))
    end
  end

  MISSING_RUNTIME = { 'TAMOZ_RUNTIME_DIR' => '/no/such/runtime' }.freeze

  def test_a_named_model_does_not_read_the_runtime
    named = builder(MISSING_RUNTIME).build({ provider: 'zai', model: 'glm-5.3-flash' })

    assert_equal %w[zai glm-5.3-flash], pair(named)
  end

  def test_a_model_named_alone_runs_when_the_runtime_cannot_be_read
    assert_equal %w[openai gpt-4o],
                 pair(builder(MISSING_RUNTIME.merge('OPENAI_API_KEY' => 'k')).build({ model: 'gpt-4o' }))
  end

  def test_no_profile_means_no_roles_without_reading_the_runtime
    assert_empty builder(MISSING_RUNTIME).resolve_profile_roles(nil, {})
  end

  def test_an_empty_runtime_variable_is_unset
    assert_raises(OptionParser::MissingArgument) { builder('TAMOZ_RUNTIME_DIR' => '').build({}) }
  end

  def test_one_runtime_spelled_two_ways_is_read_once
    with_runtime(CHAT) do |path|
      models = builder
      first = models.build({ runtime_dir: path })
      write_models(path, 'chat' => { 'provider' => 'zai', 'model' => 'glm-4.6' })
      relative = Dir.chdir(File.dirname(path)) { models.build({ runtime_dir: File.basename(path) }) }

      assert_equal pair(first), pair(relative)
    end
  end

  def test_without_a_runtime_or_a_flag_the_model_is_named_as_missing
    error = assert_raises(OptionParser::MissingArgument) { builder.build({}) }

    assert_match(/models\.chat in the runtime config/, error.message)
  end

  def test_a_role_model_comes_from_the_runtime_with_its_own_key_and_base
    with_runtime('transcription' => SPEECH, 'vision' => SPEECH.merge('model' => 'openai/gpt-4o-mini')) do |path|
      env = { 'OPENROUTER_SPEECH_API_KEY' => 'speech-key' }

      assert_equal [%w[openrouter openai/gpt-4o-mini-transcribe], %w[openrouter openai/gpt-4o-mini]],
                   [pair(attachment_for('TRANSCRIPTION', path, env)), pair(attachment_for('VISION', path, env))]
    end
  end

  def test_a_role_without_its_key_is_named
    with_runtime('transcription' => SPEECH) do |path|
      error = assert_raises(Tamoz::Agent::ModelCallError) { attachment_for('TRANSCRIPTION', path) }

      assert_equal 'credential_unavailable', error.code
    end
  end

  def test_a_role_not_configured_is_none
    with_runtime('transcription' => SPEECH) { |path| assert_nil attachment_for('VISION', path) }
  end

  def test_the_voice_role_builds_a_speaking_transport_with_a_short_timeout
    voice = SPEECH.merge('model' => 'hexgrad/kokoro-82m', 'voice' => 'af_heart')
    with_runtime('voice' => voice) do |path|
      built = attachment_for('VOICE', path, 'OPENROUTER_SPEECH_API_KEY' => 'k')

      assert_equal ['hexgrad/kokoro-82m', 10], [built.model, built.timeout_seconds]
    end
  end
end
