# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/local_model_endpoint'
require 'ruby_llm'

# Phase 2 D7: the canonical episode transport and the RubyLLM adapter must
# agree on what matters today (extracted content, usage tokens against one real
# HTTP envelope), and their known divergences stay pinned as named assertions —
# connection-error taxonomy, retry posture, and request bytes (the phase-3
# convergence target).
class ModelTransportParityTest < Minitest::Test
  SYSTEM = 'You are terse.'
  PROMPT = 'Reply with compact JSON.'
  CONTENT = '{"ok":true}'

  def test_identical_envelope_extracts_equal_content_through_both_transports
    Dir.mktmpdir('tamoz-parity') do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses: [CONTENT], log_path: File.join(dir, 'boundary.jsonl')
      ).start

      transport = Tamoz::Agent::EpisodeModelTransport.new(
        endpoint: endpoint.base_url, model: 'local-model', api_key: 'test-key'
      )
      response = transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))

      via_adapter = Tamoz::Agent::RubyLLMModel.new(
        model: 'local-model', provider: :openai, api_key: 'test-key',
        api_base: endpoint.base_url, assume_model_exists: true
      ).generate(stage: :plan, system: SYSTEM, prompt: PROMPT)

      assert_equal CONTENT, response.content
      assert_equal CONTENT, via_adapter
    ensure
      endpoint&.stop
    end
  end

  # Usage is observed at the SDK message object because the adapter returns
  # content only (post-D4 narrowing); both projections must read the same
  # envelope constants.
  def test_usage_tokens_agree_across_both_projections_of_one_envelope
    Dir.mktmpdir('tamoz-parity') do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses: [CONTENT, CONTENT], log_path: File.join(dir, 'boundary.jsonl')
      ).start

      transport = Tamoz::Agent::EpisodeModelTransport.new(
        endpoint: endpoint.base_url, model: 'local-model', api_key: 'test-key'
      )
      response = transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))

      Encoding.default_external = Encoding::UTF_8 unless
        Encoding.default_external == Encoding::UTF_8
      context = RubyLLM.context do |config|
        config.openai_api_key = 'test-key'
        config.openai_api_base = endpoint.base_url
      end
      message = context.chat(model: 'local-model', provider: :openai, assume_model_exists: true)
                       .with_instructions(SYSTEM).ask(PROMPT)

      assert_equal [42, 21], [response.usage.input_tokens, response.usage.output_tokens]
      assert_equal [42, 21], [message.input_tokens, message.output_tokens]
    ensure
      endpoint&.stop
    end
  end

  def test_connection_refused_surfaces_divergent_classes_and_retry_counts
    refused = TCPServer.new('127.0.0.1', 0)
    port = refused.addr[1]
    refused.close

    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: "http://127.0.0.1:#{port}", model: 'local-model', api_key: 'test-key'
    )
    transport_error = assert_raises(StandardError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
    end

    Encoding.default_external = Encoding::UTF_8 unless
      Encoding.default_external == Encoding::UTF_8
    require 'faraday'
    context = RubyLLM.context do |config|
      config.openai_api_key = 'test-key'
      config.openai_api_base = "http://127.0.0.1:#{port}"
    end
    sdk_error = assert_raises(StandardError) do
      context.chat(model: 'local-model', provider: :openai, assume_model_exists: true)
             .with_instructions(SYSTEM).ask(PROMPT)
    end

    assert_instance_of Errno::ECONNREFUSED, transport_error
    assert_equal 'Faraday::ConnectionFailed', sdk_error.class.name
  ensure
    refused&.close
  end

  def test_retry_posture_differs_between_single_shot_and_faraday
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    hits = Queue.new
    acceptor = Thread.new do
      loop do
        socket = server.accept
        hits << 1
        socket.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: "http://127.0.0.1:#{port}", model: 'local-model', api_key: 'test-key'
    )
    assert_raises(StandardError) do
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))
    end
    transport_hits = drain(hits)

    Encoding.default_external = Encoding::UTF_8 unless
      Encoding.default_external == Encoding::UTF_8
    require 'faraday'
    context = RubyLLM.context do |config|
      config.openai_api_key = 'test-key'
      config.openai_api_base = "http://127.0.0.1:#{port}"
    end
    assert_raises(StandardError) do
      context.chat(model: 'local-model', provider: :openai, assume_model_exists: true)
             .with_instructions(SYSTEM).ask(PROMPT)
    end
    sdk_hits = drain(hits)

    assert_equal 1, transport_hits
    assert_operator sdk_hits, :>, 1, 'faraday should retry connection failures'
  ensure
    server&.close
    acceptor&.join(1)
  end

  def test_request_bytes_never_agree_across_the_transports
    Dir.mktmpdir('tamoz-parity') do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses: [CONTENT, CONTENT], log_path: File.join(dir, 'boundary.jsonl')
      ).start

      transport = Tamoz::Agent::EpisodeModelTransport.new(
        endpoint: endpoint.base_url, model: 'local-model', api_key: 'test-key'
      )
      transport.call(transport.build_request(system: SYSTEM, prompt: PROMPT))

      Tamoz::Agent::RubyLLMModel.new(
        model: 'local-model', provider: :openai, api_key: 'test-key',
        api_base: endpoint.base_url, assume_model_exists: true
      ).generate(stage: :plan, system: SYSTEM, prompt: PROMPT)

      digests = endpoint.observed.map { |row| row.fetch('request_digest') }

      assert_equal 2, digests.length
      refute_equal digests.fetch(0), digests.fetch(1),
                   'frozen SETTINGS bytes vs provider defaults must not converge here'
    ensure
      endpoint&.stop
    end
  end

  private

  def drain(queue)
    count = 0
    count += queue.pop until queue.empty?
    count
  end
end
