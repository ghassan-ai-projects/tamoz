# frozen_string_literal: true

require_relative 'test_helper'

class ModelConversationTest < Minitest::Test
  MESSAGES = [{ 'role' => 'system', 'content' => 'You are Tamoz.' },
              { 'role' => 'user', 'content' => 'Fix it.' }].freeze
  TOOLS = [{ 'type' => 'function',
             'function' => { 'name' => 'read_file', 'description' => 'Read.',
                             'parameters' => { 'type' => 'object' } } }].freeze
  TOOL_CALL = { 'id' => 'call_1', 'type' => 'function',
                'function' => { 'name' => 'read_file', 'arguments' => '{"path":"a.rb"}' } }.freeze

  def envelope(message, usage: { 'prompt_tokens' => 100, 'completion_tokens' => 9, 'prompt_cache_hit_tokens' => 64 })
    JSON.generate('choices' => [{ 'message' => message, 'finish_reason' => 'tool_calls' }], 'usage' => usage)
  end

  def test_request_carries_messages_and_tool_schemas_as_canonical_bytes
    request = JSON.parse(transport.build_conversation(messages: MESSAGES, tools: TOOLS))

    assert_equal [MESSAGES, TOOLS, 'auto'], request.values_at('messages', 'tools', 'tool_choice')
    refute request.key?('response_format')
    assert_equal transport.build_conversation(messages: MESSAGES, tools: TOOLS),
                 transport.build_conversation(messages: MESSAGES.map(&:dup), tools: TOOLS)
  end

  def test_a_request_without_tools_sends_no_tool_fields
    request = JSON.parse(transport.build_conversation(messages: MESSAGES))

    refute request.key?('tools')
    refute request.key?('tool_choice')
  end

  def test_tool_calls_are_parsed_and_null_content_becomes_empty
    response = replaying(envelope({ 'role' => 'assistant', 'content' => nil, 'tool_calls' => [TOOL_CALL] }))
               .converse(stage: :work, messages: MESSAGES, tools: TOOLS)

    assert_equal '', response.content
    assert_equal [{ 'id' => 'call_1', 'name' => 'read_file', 'arguments' => '{"path":"a.rb"}' }], response.tool_calls
    assert_equal 'tool_calls', response.finish_reason
  end

  def test_provider_usage_is_kept_raw_for_the_context_engine
    openai = { 'prompt_tokens' => 100, 'completion_tokens' => 9, 'prompt_tokens_details' => { 'cached_tokens' => 32 } }
    deepseek = Tamoz::ContextEngine::Usage.from_provider(converse_usage(envelope(assistant)))

    assert_equal [100, 64], [deepseek.prompt_tokens, deepseek.cache_read_tokens]
    assert_equal 32,
                 Tamoz::ContextEngine::Usage.from_provider(converse_usage(envelope(assistant,
                                                                                   usage: openai))).cache_read_tokens
    assert_nil converse_usage(envelope(assistant, usage: 'n/a'))
  end

  def test_conversations_refuse_the_witness_gateway
    gateway = Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'https://example.test/v1', model: 'm',
                                                      provider: 'deepseek', gateway: Object.new)

    assert_raises(Tamoz::ConfigurationError) { gateway.converse(stage: :work, messages: MESSAGES) }
  end

  def test_a_role_setting_wins_over_the_environment
    role = Tamoz::Agent::ModelCall::ModelRole.new(
      name: 'primary', provider: 'deepseek', model: 'deepseek-chat', revision: nil,
      normalized_settings: { 'context_window' => '32768' }, credential_ref: nil, profile_digest: nil
    )
    environment = { 'DEEPSEEK_API_KEY' => 'k', 'TAMOZ_CONTEXT_WINDOW' => '99' }
    transport = Tamoz::Agent::ModelClientFactory.build(provider: 'deepseek', model: 'deepseek-chat', profile_role: role,
                                                       environment:)

    assert_equal 32_768, transport.context_window
  end

  def test_a_context_window_rejection_has_its_own_code
    body = '{"error":{"message":"This model\'s maximum context length is 65536 tokens"}}'
    error = assert_raises(Tamoz::Agent::ModelCallError) do
      replaying(body, http: Net::HTTPBadRequest.new('1.1', '400', 'Bad Request'))
        .converse(stage: :work, messages: MESSAGES)
    end

    assert_equal 'context_window_exceeded', error.code
  end

  def test_other_bad_requests_stay_http_failures
    error = assert_raises(Tamoz::Agent::ModelCallError) do
      replaying('{"error":"bad"}', http: Net::HTTPBadRequest.new('1.1', '400', 'Bad Request'))
        .converse(stage: :work, messages: MESSAGES)
    end

    assert_equal 'http_failure', error.code
  end

  def test_projection_round_trips_and_binds_the_request_digest
    replay = replaying(envelope({ 'role' => 'assistant', 'content' => 'done' }))
    response = replay.converse(stage: :work, messages: MESSAGES)
    projection = Tamoz::Agent::ConversationProjection.from_response(response, request_digest: response.request_digest)

    assert_equal projection, Tamoz::Agent::ConversationProjection.validate!(projection.to_h)
    assert_raises(Tamoz::Agent::ModelReceiptError) do
      Tamoz::Agent::ConversationProjection.validate!(projection.merge('response_digest' => 'not-a-digest'))
    end
    assert_raises(Tamoz::Agent::ModelCallError) do
      Tamoz::Agent::ConversationProjection.from_response(response, request_digest: 'sha256:other')
    end
  end

  def test_context_window_comes_from_the_role_or_environment_and_is_never_guessed
    assert_equal 65_536, factory_window({ 'TAMOZ_CONTEXT_WINDOW' => '65536' })
    assert_nil factory_window({})
    assert_raises(Tamoz::Agent::ModelCallError) { factory_window({ 'TAMOZ_CONTEXT_WINDOW' => 'lots' }) }
  end

  private

  def assistant = { 'role' => 'assistant', 'content' => 'ok' }

  def converse_usage(body) = replaying(body).converse(stage: :work, messages: MESSAGES).usage

  def factory_window(env)
    Tamoz::Agent::ModelClientFactory.build(
      provider: 'deepseek', model: 'deepseek-chat', profile_role: nil,
      environment: env.merge('DEEPSEEK_API_KEY' => 'k')
    ).context_window
  end

  def transport
    Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'https://example.test/v1', model: 'deepseek-chat',
                                            provider: 'deepseek')
  end

  def replaying(body, http: Net::HTTPOK.new('1.1', '200', 'OK'))
    http.instance_variable_set(:@body, body)
    http.instance_variable_set(:@read, true)
    Class.new(Tamoz::Agent::EpisodeModelTransport) do
      define_method(:post_completion_request) { |_body, **| http }
    end.new(endpoint: 'https://example.test/v1', model: 'deepseek-chat', provider: 'deepseek', api_key: 'k')
  end
end
