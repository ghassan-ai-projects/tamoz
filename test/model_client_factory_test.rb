# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/local_model_endpoint'

class ModelClientFactoryTest < Minitest::Test
  Factory = Tamoz::Agent::ModelClientFactory
  Role = Tamoz::Agent::ModelCall::ModelRole
  DIGEST = "sha256:#{"c" * 64}"

  PROVIDERS = {
    'openai' => ['OPENAI_API_KEY', 'https://api.openai.com/v1'],
    'deepseek' => ['DEEPSEEK_API_KEY', 'https://api.deepseek.com'],
    'openrouter' => ['OPENROUTER_API_KEY', 'https://openrouter.ai/api/v1'],
    'ollama' => ['OLLAMA_API_KEY', 'http://localhost:11434/v1'],
    'xai' => ['XAI_API_KEY', 'https://api.x.ai/v1'],
    'perplexity' => ['PERPLEXITY_API_KEY', 'https://api.perplexity.ai/v1'],
    'mistral' => ['MISTRAL_API_KEY', 'https://api.mistral.ai/v1'],
    'anthropic' => ['ANTHROPIC_API_KEY', nil],
    'gemini' => ['GEMINI_API_KEY', nil]
  }.freeze

  def test_provider_descriptor_exposes_the_closed_phase_three_matrix
    PROVIDERS.each do |provider, (credential, endpoint)|
      names = Factory.environment_names(provider:)

      assert_includes names, credential
      assert_includes names, "#{provider.upcase}_API_BASE"
      if endpoint
        assert_equal endpoint, Factory::DESCRIPTORS.fetch(provider).fetch(:default_base)
      else
        assert_nil Factory::DESCRIPTORS.fetch(provider).fetch(:default_base)
      end
    end
  end

  def test_factory_requires_the_profile_credential_without_generic_fallback
    role = role(credential_ref: {"kind" => "env", "name" => "TAMOZ_MODEL_SECRET"})

    error = assert_raises(Tamoz::Agent::ProfileRoleUnavailableError) do
      Factory.build(
        provider: 'openai', model: 'gpt-test', profile_role: role,
        environment: {'OPENAI_API_KEY' => 'generic-key'}
      )
    end

    assert_includes error.message, 'TAMOZ_MODEL_SECRET'
  end

  def test_ollama_without_a_key_does_not_treat_its_endpoint_as_a_credential
    assert_nil Factory.credential_reference(
      provider: 'ollama', profile_role: nil, environment: {'OLLAMA_API_BASE' => 'http://localhost:11434/v1'}
    )
  end

  def test_factory_rejects_an_api_base_name_as_a_profile_credential
    # A credential_ref naming an API-base variable is a malformed role
    # reference, so it fails typed (ProfileRoleUnavailableError), matching the
    # DR-5 D1 taxonomy in tamoz-agent-kernel errors.rb.
    error = assert_raises(Tamoz::Agent::ProfileRoleUnavailableError) do
      Factory.build(
        provider: 'ollama', model: 'local-model',
        profile_role: role(
          provider: 'ollama', model: 'local-model',
          credential_ref: {'kind' => 'env', 'name' => 'OLLAMA_API_BASE'}
        ),
        environment: {'OLLAMA_API_BASE' => 'http://localhost:11434/v1'}
      )
    end

    assert_includes error.message, 'credential_reference_invalid'
  end

  def test_factory_binds_profile_and_explicit_endpoint_configuration_without_secret
    secret = 'factory-secret-sentinel'
    role = role(
      normalized_settings: {'base_url' => 'https://profile.example/v1'},
      credential_ref: {"kind" => "env", "name" => "TAMOZ_MODEL_SECRET"}
    )
    from_profile = Factory.build(
      provider: 'openai', model: 'gpt-test', profile_role: role,
      environment: {'TAMOZ_MODEL_SECRET' => secret}
    )
    from_explicit = Factory.build(
      provider: 'openai', model: 'gpt-test', profile_role: role,
      explicit_api_base: 'https://explicit.example/v1',
      environment: {'TAMOZ_MODEL_SECRET' => secret}
    )

    refute_equal from_profile.provider_configuration_digest, from_explicit.provider_configuration_digest
    refute_includes from_profile.inspect, secret
    refute_includes from_explicit.inspect, secret
    refute_includes from_profile.provider_configuration_digest, secret
  end

  def test_factory_uses_the_profile_credential_at_the_http_boundary
    secret = 'profile-credential-sentinel'
    observed_headers = nil
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(
      :@body,
      JSON.generate(
        'choices' => [{'message' => {'content' => '{"ok":true}'}}]
      )
    )
    # The transport freezes at construction, so the HTTP boundary is
    # overridden on an anonymous subclass; a hand-built response is marked
    # pre-read because it has no socket to stream from.
    response.instance_variable_set(:@read, true)
    transport = Class.new(Tamoz::Agent::EpisodeModelTransport) do
      define_method(:post_completion_request) do |_body, headers:|
        observed_headers = headers
        response
      end
    end.new(
      endpoint: 'https://example.test/v1', model: 'gpt-test', provider: 'openai',
      api_key: secret, safety: :unsafe
    )
    transport.generate(stage: :plan, system: 'system', prompt: 'prompt')

    assert_equal "Bearer #{secret}", observed_headers['Authorization']
  end

  def test_factory_built_transport_crosses_the_real_http_boundary
    Dir.mktmpdir('tamoz-factory') do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses: ['{"ok":true}'], log_path: File.join(dir, 'boundary.jsonl')
      ).start
      transport = Factory.build(
        provider: 'openai', model: 'local-model', profile_role: nil,
        explicit_api_base: endpoint.base_url, environment: {'OPENAI_API_KEY' => 'factory-key'}
      )

      response = transport.generate(stage: :plan, system: 'system', prompt: 'prompt')

      assert_equal '{"ok":true}', response.content
      assert_equal transport.request_digest(transport.build_request(system: 'system', prompt: 'prompt')),
                   endpoint.observed.fetch(0).fetch('request_digest')
    ensure
      endpoint&.stop
    end
  end

  def test_native_protocols_and_unknown_providers_fail_closed
    native = assert_raises(Tamoz::Agent::ModelCallError) do
      Factory.build(
        provider: 'anthropic', model: 'claude-test', profile_role: nil,
        environment: {'ANTHROPIC_API_KEY' => 'key'}
      )
    end
    unsupported = assert_raises(Tamoz::Agent::ModelCallError) do
      Factory.build(provider: 'unknown', model: 'model', profile_role: nil, environment: {})
    end

    assert_equal 'native_protocol_rejected', native.code
    assert_equal 'unsupported_provider', unsupported.code
  end

  def test_openrouter_requires_a_provider_qualified_model_identifier
    error = assert_raises(Tamoz::Agent::ModelCallError) do
      Factory.build(
        provider: 'openrouter', model: 'unqualified-model', profile_role: nil,
        environment: {'OPENROUTER_API_KEY' => 'key'}
      )
    end

    assert_equal 'model_invalid', error.code
  end

  def test_factory_rejects_a_model_or_provider_that_does_not_match_the_profile_role
    error = assert_raises(Tamoz::Agent::ModelCallError) do
      Factory.build(
        provider: 'deepseek', model: 'other-model', profile_role: role,
        environment: {'OPENAI_API_KEY' => 'key'}
      )
    end

    assert_equal 'profile_role_mismatch', error.code
  end

  private

  def role(provider: 'openai', model: 'gpt-test', normalized_settings: {}, credential_ref: nil)
    Role.new(
      name: 'primary', provider:, model:, revision: 1,
      normalized_settings:, credential_ref:, profile_digest: DIGEST
    )
  end
end
