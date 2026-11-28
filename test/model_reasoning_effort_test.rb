# frozen_string_literal: true

require_relative 'test_helper'

class ModelReasoningEffortTest < Minitest::Test
  FROZEN_SETTINGS_DIGEST = 'sha256:dbf54ff0613228eb68eebbac3fd7657c63d9ee1971b8db58d6dafc86513c6549'
  FROZEN_CONVERSATION_DIGEST = 'sha256:5008868ee0603233f7c64df5c24b53b2b6080c11e1ab9ba5b40cedcbbdb216ba'
  FROZEN_REQUEST = '{"messages":[{"content":"s","role":"system"},{"content":"p","role":"user"}],' \
                   '"model":"m","response_format":{"type":"json_object"},"stream":false,"temperature":0}'
  FROZEN_CONVERSATION = '{"messages":[],"model":"m","stream":false,"temperature":0}'

  def test_unset_keeps_the_request_bytes
    transport = build

    assert_nil transport.reasoning_effort
    assert_equal FROZEN_REQUEST, transport.build_request(system: 's', prompt: 'p')
    assert_equal FROZEN_CONVERSATION, transport.build_conversation(messages: [])
  end

  def test_unset_keeps_the_settings_digests
    transport = build

    assert_equal FROZEN_SETTINGS_DIGEST, transport.settings_digest
    assert_equal FROZEN_CONVERSATION_DIGEST, transport.conversation_settings_digest
  end

  def test_set_adds_the_field_to_both_requests
    transport = build(reasoning_effort: 'max')

    assert_equal 'max', JSON.parse(transport.build_request(system: 's', prompt: 'p')).fetch('reasoning_effort')
    assert_equal 'max', JSON.parse(transport.build_conversation(messages: [])).fetch('reasoning_effort')
  end

  def test_set_changes_both_settings_digests
    transport = build(reasoning_effort: 'max')

    refute_equal FROZEN_SETTINGS_DIGEST, transport.settings_digest
    refute_equal FROZEN_CONVERSATION_DIGEST, transport.conversation_settings_digest
    refute_equal transport.settings_digest, build(reasoning_effort: 'high').settings_digest
  end

  def test_set_changes_the_provider_configuration_digest
    refute_equal build.provider_configuration_digest, build(reasoning_effort: 'max').provider_configuration_digest
  end

  def test_every_documented_value_is_accepted_and_others_are_refused
    %w[low high xhigh max].each { |value| assert_equal value, build(reasoning_effort: value).reasoning_effort }
    ['', 'MAX', 'medium', 'extreme'].each do |value|
      error = assert_raises(Tamoz::ConfigurationError) { build(reasoning_effort: value) }
      assert_match(/reasoning_effort must be one of low, high, xhigh, max/, error.message)
    end
  end

  def test_a_profile_role_setting_reaches_the_transport_request
    transport = from_role('max')

    assert_equal 'max', transport.reasoning_effort
    assert_equal 'max', JSON.parse(transport.build_request(system: 's', prompt: 'p')).fetch('reasoning_effort')
  end

  def test_a_profile_role_setting_is_bound_by_the_digests
    plain = from_role(nil)
    max = from_role('max')

    assert_nil plain.reasoning_effort
    refute_equal plain.provider_configuration_digest, max.provider_configuration_digest
    refute_equal plain.settings_digest, max.settings_digest
  end

  def test_an_invalid_profile_role_value_is_a_configuration_error
    assert_raises(Tamoz::ConfigurationError) { from_role('medium') }
  end

  def test_the_profile_document_refuses_an_invalid_value_at_load
    max = preview_profile('max')
    error = assert_raises(Tamoz::Agent::Profile::ValidationError) { preview_profile('medium') }

    assert_equal 'max', max.model_roles.dig('reasoner', 'normalized_settings', 'reasoning_effort')
    assert_match(/reasoning_effort for "reasoner" must be one of low, high, xhigh, max/, error.message)
  end

  private

  def build(**)
    Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'https://e.test/v1', model: 'm', provider: 'deepseek', **)
  end

  def from_role(effort)
    settings = effort ? { 'reasoning_effort' => effort } : {}
    role = Tamoz::Agent::ModelCall::ModelRole.new(
      name: 'reasoner', provider: 'opencode_go', model: 'deepseek-v4.1-flash', revision: nil,
      normalized_settings: settings, credential_ref: nil, profile_digest: nil
    )
    Tamoz::Agent::ModelClientFactory.build(provider: 'opencode_go', model: 'deepseek-v4.1-flash',
                                           profile_role: role, environment: { 'OPEN_CODE_API_KEY' => 'k' })
  end

  def preview_profile(effort)
    Dir.mktmpdir('tamoz-effort') do |dir|
      path = File.join(dir, 'profile.yaml')
      File.write(path, Psych.dump(profile_document(dir, effort)))
      File.chmod(0o600, path)
      Tamoz::Agent::Profile.preview(path, suggestion: true)
    end
  end

  def profile_document(dir, effort)
    {
      'profile' => { 'schema_version' => 1, 'profile_id' => 'effort-profile', 'profile_version' => '1.0',
                     'canonical_root' => dir },
      'roots' => { 'workspace' => dir },
      'model_roles' => { 'reasoner' => { 'provider' => 'opencode_go', 'model' => 'deepseek-v4.1-flash',
                                         'normalized_settings' => { 'reasoning_effort' => effort } } },
      'tools' => { 'allowed' => %w[read_file] },
      'policy' => { 'allow_changes' => false, 'default_check_safety' => 'read_only', 'graph_version' => '1',
                    'behavior_version' => '1.0', 'tool_catalog_digest' => "sha256:#{'a' * 64}" }
    }
  end
end
