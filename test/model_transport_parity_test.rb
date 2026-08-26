# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/local_model_endpoint'

class ModelTransportParityTest < Minitest::Test
  SYSTEM = 'You are terse.'
  PROMPT = 'Reply with compact JSON.'
  CONTENT = '{"ok":true}'
  SECOND_CONTENT = '{"ok":false}'

  def test_generate_returns_the_complete_digest_bound_projection
    with_endpoint([CONTENT]) do |endpoint|
      transport = transport_for(endpoint)
      response = transport.generate(stage: :plan, system: SYSTEM, prompt: PROMPT)
      observed = endpoint.observed.fetch(0)
      projection = Tamoz::Agent::ModelCallProjection.from_response(response)

      assert_equal CONTENT, response.content
      assert_equal [42, 21], [response.usage.input_tokens, response.usage.output_tokens]
      assert_equal observed.fetch('request_digest'), response.request_digest
      assert_equal observed.fetch('response_digest'), response.response_digest
      assert_equal transport.settings_digest, response.settings_digest
      assert_equal transport.provider_configuration_digest, response.provider_configuration_digest
      assert_equal %w[
        content provider_configuration_digest request_digest response_digest settings_digest usage
      ], projection.keys.sort
    end
  end

  def test_same_request_bytes_are_stable_while_response_digests_track_envelopes
    with_endpoint([CONTENT, SECOND_CONTENT]) do |endpoint|
      transport = transport_for(endpoint)
      request = transport.build_request(system: SYSTEM, prompt: PROMPT)
      first = transport.call(request)
      second = transport.call(request)
      observations = endpoint.observed

      assert_equal first.request_digest, second.request_digest
      assert_equal observations.map { |row| row.fetch('request_digest') }.uniq.length, 1
      assert_equal first.response_digest, observations.fetch(0).fetch('response_digest')
      assert_equal second.response_digest, observations.fetch(1).fetch('response_digest')
      refute_equal first.response_digest, second.response_digest
    end
  end

  def test_received_http_failure_is_typed_and_redacted
    body = '{"error":"provider-secret-sentinel"}'
    response = Net::HTTPInternalServerError.new('1.1', '503', 'Service Unavailable')
    response.instance_variable_set(:@body, body)
    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: 'https://example.test/v1', model: 'model', provider: 'openai',
      api_key: 'provider-secret-sentinel'
    )

    error = assert_raises(Tamoz::Agent::ModelCallError) do
      transport.stub(:post_completion_request, response) do
        transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
      end
    end

    assert_equal 'http_failure', error.code
    assert_equal 503, error.status
    assert_equal body.bytesize, error.body_bytes
    refute_includes error.message, 'provider-secret-sentinel'
  end

  def test_transport_does_not_retry_a_received_failure
    response = Net::HTTPBadGateway.new('1.1', '502', 'Bad Gateway')
    response.instance_variable_set(:@body, '{}')
    calls = 0
    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: 'https://example.test/v1', model: 'model', provider: 'openai'
    )

    assert_raises(Tamoz::Agent::ModelCallError) do
      transport.stub(:post_completion_request, lambda { |_body, headers:|
        calls += 1
        response
      }) do
        transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
      end
    end

    assert_equal 1, calls
  end

  def test_malformed_response_projection_becomes_a_typed_failed_model_call
    response = Tamoz::Agent::EpisodeModelTransport::Response.new(
      content: CONTENT, request_digest: 'bad', response_digest: digest,
      usage: Tamoz::Agent::ModelCall::Usage.unavailable,
      settings_digest: digest, provider_configuration_digest: digest
    )

    error = assert_raises(Tamoz::Agent::ModelCallError) do
      Tamoz::Agent::ModelCallProjection.from_response(response)
    end

    assert_equal 'invalid_projection', error.code
    refute_includes error.message, 'bad'
  end

  def test_partial_or_malformed_usage_is_unavailable
    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: 'http://example.test/v1', model: 'model', provider: 'openai'
    )

    partial = transport.send(:usage_from, {'prompt_tokens' => 42})
    malformed = transport.send(:usage_from, nil)

    refute partial.available
    refute malformed.available
    assert_nil partial.input_tokens
    assert_nil malformed.output_tokens
  end

  private

  def with_endpoint(responses)
    Dir.mktmpdir('tamoz-transport') do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses:, log_path: File.join(dir, 'boundary.jsonl')
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def transport_for(endpoint)
    Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: endpoint.base_url, model: 'local-model', provider: 'openai', api_key: 'test-key'
    )
  end

  def digest
    "sha256:#{"a" * 64}"
  end
end
