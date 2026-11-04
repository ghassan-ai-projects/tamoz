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
      projection = Tamoz::Agent::ModelCallProjection.from_response(response)

      assert_equal expected_fields(transport, endpoint.observed.fetch(0)), response_fields(response)
      assert_equal %w[
        content provider_configuration_digest provider_retries request_digest response_digest settings_digest usage
      ], projection.keys.sort
    end
  end

  def test_same_request_bytes_are_stable_across_envelopes
    with_two_calls do |first, second, observations|
      assert_equal first.request_digest, second.request_digest
      assert_equal 1, observations.map { |row| row.fetch('request_digest') }.uniq.length
    end
  end

  def test_response_digests_track_envelopes
    with_two_calls do |first, second, observations|
      assert_equal([first.response_digest, second.response_digest],
                   observations.map { |row| row.fetch('response_digest') })
      refute_equal first.response_digest, second.response_digest
    end
  end

  def test_received_http_failure_is_typed_and_redacted
    body = '{"error":"provider-secret-sentinel"}'
    response = Net::HTTPInternalServerError.new('1.1', '503', 'Service Unavailable')
    response.instance_variable_set(:@body, body)
    transport = replaying_transport(response, api_key: 'provider-secret-sentinel')

    error = assert_raises(Tamoz::Agent::ModelCallError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
    end

    assert_equal ['http_failure', 503, body.bytesize], [error.code, error.status, error.body_bytes]
    refute_includes error.message, 'provider-secret-sentinel'
  end

  def test_transport_does_not_retry_a_received_failure
    response = Net::HTTPBadGateway.new('1.1', '502', 'Bad Gateway')
    response.instance_variable_set(:@body, '{}')
    calls = 0
    transport = replaying_transport(response) { calls += 1 }

    assert_raises(Tamoz::Agent::ModelCallError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
    end

    assert_equal 1, calls
  end

  def test_transport_retries_a_503_up_to_the_limit_and_honours_retry_after
    response = Net::HTTPServiceUnavailable.new('1.1', '503', 'Service Unavailable')
    response.instance_variable_set(:@body, '{}')
    response['Retry-After'] = '4'
    calls = 0
    pauses = []
    transport = replaying_transport(response, pause: pauses.method(:push)) { calls += 1 }

    error = assert_raises(Tamoz::Agent::ModelCallError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT), max_retries: 1)
    end

    assert_equal 503, error.status
    assert_equal [2, [4]], [calls, pauses]
  end

  def test_transport_never_retries_other_statuses_whatever_the_limit
    response = Net::HTTPBadGateway.new('1.1', '502', 'Bad Gateway')
    response.instance_variable_set(:@body, '{}')
    calls = 0
    transport = replaying_transport(response) { calls += 1 }

    assert_raises(Tamoz::Agent::ModelCallError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT), max_retries: 2)
    end

    assert_equal 1, calls
  end

  def test_malformed_response_projection_becomes_a_typed_failed_model_call
    response = Tamoz::Agent::EpisodeModelTransport::Response.new(
      content: CONTENT, request_digest: 'bad', response_digest: digest,
      usage: Tamoz::Agent::ModelCall::Usage.unavailable,
      settings_digest: digest, provider_configuration_digest: digest, provider_retries: 0
    )

    error = assert_raises(Tamoz::Agent::ModelCallError) do
      Tamoz::Agent::ModelCallProjection.from_response(response)
    end

    assert_equal 'invalid_projection', error.code
    refute_includes error.message, 'bad'
  end

  def test_partial_or_malformed_usage_is_unavailable
    wire = Tamoz::Agent::EpisodeModelTransport::Wire
    partial = wire.usage_from({ 'prompt_tokens' => 42 })
    malformed = wire.usage_from(nil)

    assert_equal [false, false, nil, nil],
                 [partial.available, malformed.available, partial.input_tokens, malformed.output_tokens]
  end

  private

  # The transports freeze at construction, so the HTTP boundary is overridden
  # on an anonymous subclass instead of patched per instance. The response is
  # marked pre-read: a hand-built Net::HTTP response has no socket to stream
  # from.
  def replaying_transport(response, api_key: nil, pause: nil, &on_request)
    response.instance_variable_set(:@read, true)
    transport_class = Class.new(Tamoz::Agent::EpisodeModelTransport) do
      define_method(:post_completion_request) do |_body, **|
        on_request&.call
        response
      end
    end
    transport_class.new(
      endpoint: 'https://example.test/v1', model: 'model', provider: 'openai', api_key:, pause:
    )
  end

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

  def with_two_calls
    with_endpoint([CONTENT, SECOND_CONTENT]) do |endpoint|
      transport = transport_for(endpoint)
      request = transport.build_request(system: SYSTEM, prompt: PROMPT)
      first = transport.call(request)
      second = transport.call(request)
      yield first, second, endpoint.observed
    end
  end

  def expected_fields(transport, observed)
    {
      content: CONTENT, usage: [42, 21],
      request_digest: observed.fetch('request_digest'), response_digest: observed.fetch('response_digest'),
      settings_digest: transport.settings_digest,
      provider_configuration_digest: transport.provider_configuration_digest
    }
  end

  def response_fields(response)
    {
      content: response.content, usage: [response.usage.input_tokens, response.usage.output_tokens],
      request_digest: response.request_digest, response_digest: response.response_digest,
      settings_digest: response.settings_digest,
      provider_configuration_digest: response.provider_configuration_digest
    }
  end

  def transport_for(endpoint)
    Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: endpoint.base_url, model: 'local-model', provider: 'openai', api_key: 'test-key'
    )
  end

  def digest
    "sha256:#{'a' * 64}"
  end
end
