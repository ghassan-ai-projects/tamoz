# frozen_string_literal: true

require_relative 'test_helper'

# The runtime's models: what `config.yaml` may say about the chat model and each model role.
class RuntimeModelsTest < Minitest::Test
  Models = Tamoz::Agent::RuntimeModels
  SPEECH = { 'provider' => 'openrouter', 'model' => 'openai/gpt-4o-mini-transcribe',
             'credential' => 'OPENROUTER_SPEECH_API_KEY' }.freeze
  KEY = 'sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef'

  def refusal(models) = assert_raises(ArgumentError) { Models.parse(models) }.message

  def test_each_role_is_read_with_its_own_fields
    models = Models.parse('chat' => { 'provider' => 'zai', 'model' => 'glm-5.3-flash' },
                          'transcription' => SPEECH.merge('api_base' => 'http://127.0.0.1:9/v1'),
                          'vision' => SPEECH.merge('model' => 'openai/gpt-4o-mini'))

    assert_equal ['zai', 'glm-5.3-flash', nil],
                 [models['chat'].provider, models['chat'].model, models['chat'].credential]
    assert_equal %w[OPENROUTER_SPEECH_API_KEY http://127.0.0.1:9/v1 openai/gpt-4o-mini],
                 [models['transcription'].credential, models['transcription'].api_base, models['vision'].model]
  end

  def test_no_models_section_means_no_models
    assert_nil Models.parse(nil)['chat']
  end

  def test_an_unknown_role_is_refused
    assert_match(/models\.speech is not a model role/, refusal('speech' => SPEECH))
  end

  def test_the_chat_model_takes_no_key_or_endpoint
    assert_match(/models\.chat does not take credential/,
                 refusal('chat' => { 'provider' => 'zai', 'model' => 'm', 'credential' => 'X_API_KEY' }))
  end

  def test_an_unknown_field_is_refused
    assert_match(/models\.transcription does not take temperature/,
                 refusal('transcription' => SPEECH.merge('temperature' => 0)))
  end

  def test_a_role_must_be_a_mapping
    assert_match(/models\.chat must be a mapping/, refusal('chat' => 'zai/glm'))
  end

  def test_provider_and_model_are_required
    assert_match(/models\.chat\.model is required/, refusal('chat' => { 'provider' => 'zai' }))
    assert_match(/models\.chat\.provider is required/, refusal('chat' => { 'provider' => ' ', 'model' => 'm' }))
  end

  def test_a_key_in_the_credential_field_is_refused_and_never_echoed
    message = refusal('transcription' => SPEECH.merge('credential' => KEY))

    assert_match(/credential must name an \*_API_KEY variable/, message)
    refute_includes message, KEY
  end

  def test_a_credential_names_an_api_key_variable_outside_tamoz
    [false, 'TAMOZ_TALK_API_KEY', 'PATH', 'OPENROUTER_SPEECH_TOKEN', 'openrouter_api_key'].each do |name|
      assert_match(/credential must name/, refusal('vision' => SPEECH.merge('credential' => name)), name.to_s)
    end
  end

  def test_an_api_base_is_an_http_url_without_credentials
    ['file:///etc/passwd', 'https://user:secret@example.com/v1', 'https://example.com/v1?key=secret',
     'not a url'].each do |url|
      assert_match(/api_base must be an http\(s\) URL without credentials or a query/,
                   refusal('transcription' => SPEECH.merge('api_base' => url)), url)
    end
  end

  def test_a_key_used_as_a_name_is_never_echoed
    refute_includes refusal(KEY => SPEECH), KEY
    refute_includes refusal('transcription' => SPEECH.merge(KEY => 'x')), KEY
  end
end
