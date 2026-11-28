# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'

class OpencodeGoProviderTest < Minitest::Test
  Factory = Tamoz::Agent::ModelClientFactory
  MESSAGES = [{ 'role' => 'user', 'content' => 'Say ok.' }].freeze
  TOOL_CALL = { 'id' => 'call_1', 'type' => 'function',
                'function' => { 'name' => 'ping', 'arguments' => '{}' } }.freeze

  def reply(message)
    JSON.generate('choices' => [{ 'message' => message, 'finish_reason' => 'stop' }],
                  'usage' => { 'prompt_tokens' => 5, 'completion_tokens' => 3 })
  end

  def serving(bodies)
    server = TCPServer.new('127.0.0.1', 0)
    heads = Queue.new
    thread = Thread.new { bodies.each { |body| answer_once(server, heads, body) } }
    yield "http://127.0.0.1:#{server.addr[1]}/v1", heads
  ensure
    thread&.join(2)
    server&.close
  end

  def answer_once(server, heads, body)
    socket = server.accept
    head = +''
    head << socket.gets until head.end_with?("\r\n\r\n")
    socket.read(head[/content-length: (\d+)/i, 1].to_i)
    heads << head.downcase
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
    socket.close
  end

  def build(provider, endpoint, model)
    Factory.build(provider:, model:, profile_role: nil, explicit_api_base: endpoint,
                  environment: { Tamoz::Agent::Providers::ENV_KEYS.fetch(provider.to_sym) => 'sk-test' })
  end

  def test_the_provider_reads_its_key_from_open_code_api_key_and_routes_to_the_go_endpoint
    assert_equal 'OPEN_CODE_API_KEY', Tamoz::Agent::Providers::ENV_KEYS.fetch(:opencode_go)
    assert_equal 'https://opencode.ai/inference/go/openai/v1', Factory::DESCRIPTORS.fetch('opencode_go')[:default_base]
    assert_includes Factory.environment_names(provider: 'opencode_go'), 'OPENCODE_GO_API_BASE'
  end

  def two_turn_heads
    serving([reply('role' => 'assistant', 'content' => '{}')] * 2) do |endpoint, heads|
      client = build('opencode_go', endpoint, 'deepseek-v4.1-flash')
      2.times { client.generate(stage: :ping, system: 's', prompt: 'p') }
      return [heads.pop, heads.pop]
    end
  end

  def test_the_client_names_tamoz_and_authenticates
    first, = two_turn_heads

    assert_includes first, "user-agent: tamoz/#{Tamoz::Agent::Kernel::VERSION}\r\n"
    assert_includes first, 'authorization: bearer sk-test'
  end

  def test_every_turn_of_one_client_keeps_one_session
    first, second = two_turn_heads

    assert_match(/^x-opencode-session: [0-9a-f]{32}\r$/, first)
    assert_equal first[/x-opencode-session: \S+/], second[/x-opencode-session: \S+/]
  end

  def test_two_clients_keep_two_sessions
    sessions = Array.new(2) { Factory.send(:client_headers, Factory::DESCRIPTORS.fetch('opencode_go')) }

    refute_equal sessions[0].fetch('x-opencode-session'), sessions[1].fetch('x-opencode-session')
  end

  def test_another_provider_sends_no_opencode_header
    serving([reply('role' => 'assistant', 'content' => '{}')]) do |endpoint, heads|
      build('openai', endpoint, 'gpt-test').generate(stage: :ping, system: 's', prompt: 'p')

      refute_includes heads.pop, 'x-opencode-session'
    end
  end

  def test_a_reply_with_reasoning_content_still_yields_content_and_tool_calls
    message = { 'role' => 'assistant', 'content' => '{"answer":"ok"}', 'reasoning_content' => 'Thinking about it.' }
    tool_message = { 'role' => 'assistant', 'content' => nil, 'reasoning_content' => 'Call the tool.',
                     'tool_calls' => [TOOL_CALL] }
    serving([reply(message), reply(tool_message)]) do |endpoint, _heads|
      client = build('opencode_go', endpoint, 'deepseek-v4.1-flash')
      generated = client.generate(stage: :ping, system: 's', prompt: 'p')
      turn = client.converse(stage: :work, messages: MESSAGES)

      assert_equal '{"answer":"ok"}', generated.content
      assert_equal [{ 'id' => 'call_1', 'name' => 'ping', 'arguments' => '{}' }], turn.tool_calls
    end
  end
end
