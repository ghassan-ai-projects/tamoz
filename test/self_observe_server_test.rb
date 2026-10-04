# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'
require 'tamoz/agent_cli'

class SelfObserveServerTest < Minitest::Test
  PROBES = {
    'targets' => {},
    'probes' => [
      { 'name' => 'probe_self_diagnose', 'description' => 'Findings about this Tamoz runtime in the window.',
        'backing' => { 'server' => 'tamoz-self', 'tool' => 'diagnose' },
        'arguments' => { 'from' => '{window.from}', 'until' => '{window.until}' } },
      { 'name' => 'probe_self_timeline', 'description' => 'Ordered failure and lifecycle events in the window.',
        'backing' => { 'server' => 'tamoz-self', 'tool' => 'timeline' },
        'arguments' => { 'from' => '{window.from}', 'until' => '{window.until}' } },
      { 'name' => 'probe_self_explain_turn', 'description' => 'The decision record of one thread.',
        'backing' => { 'server' => 'tamoz-self', 'tool' => 'explain_turn' },
        'arguments' => { 'thread_id' => { 'free' => 'string', 'max_bytes' => 128 } } }
    ]
  }.freeze

  def test_lists_three_read_only_tools
    with_server do |server|
      tools = rpc(server, 'tools/list').dig(:result, :tools)

      assert_equal %w[diagnose explain_turn timeline], tools.map { |tool| tool.fetch(:name) }.sort
      assert(tools.all? { |tool| tool.dig(:annotations, :readOnlyHint) && !tool.dig(:annotations, :destructiveHint) })
    end
  end

  def test_diagnose_returns_the_findings_of_the_window
    with_server do |server|
      result = rpc(server, 'tools/call', name: 'diagnose',
                                         arguments: { from: (Time.now - 3600).iso8601, until: (Time.now + 60).iso8601 })
      report = JSON.parse(result.dig(:result, :content, 0, :text))

      refute result.dig(:result, :isError)
      assert_includes report.fetch('findings').map { |finding| finding.fetch('rule_id') }, 'effect.outcome_unknown'
    end
  end

  def test_explain_turn_and_timeline_answer_and_errors_are_tool_errors
    with_server do |server|
      explained = rpc(server, 'tools/call', name: 'explain_turn', arguments: { thread_id: 'thread.a' })

      assert_equal 'thread.a', JSON.parse(explained.dig(:result, :content, 0, :text)).fetch('thread_id')
      timeline = rpc(server, 'tools/call', name: 'timeline', arguments: {})

      assert_operator JSON.parse(timeline.dig(:result, :content, 0, :text)).fetch('events').length, :>=, 2
    end
  end

  def test_bad_thread_and_window_are_tool_errors
    with_server do |server|
      missing = rpc(server, 'tools/call', name: 'explain_turn', arguments: { thread_id: 'thread.none' })

      assert missing.dig(:result, :isError)
      inverted = rpc(server, 'tools/call', name: 'diagnose',
                                           arguments: { from: '2026-10-02T00:00:00Z', until: '2026-10-01T00:00:00Z' })

      assert inverted.dig(:result, :isError)
    end
  end

  def test_the_probe_catalog_accepts_probes_over_the_self_observe_tools
    servers = { 'tamoz-self' => { 'read_only_tools' => Tamoz::Agent::SelfObserveServer::TOOLS.keys } }
    catalog = Tamoz::Agent::ProbeCatalog.new(PROBES, servers:)

    assert_equal %w[probe_self_diagnose probe_self_explain_turn probe_self_timeline], catalog.probes.keys.sort
    assert_predicate catalog.probe('probe_self_diagnose'), :windowed?
  end

  def test_serves_mcp_over_stdio
    with_runtime do |directory|
      responses, status = stdio_call(directory)

      assert_predicate status, :success?
      assert_equal ['tamoz-self-observe', 3], [responses.first.dig('result', 'serverInfo', 'name'),
                                               responses[1].dig('result', 'tools').length]
      diagnosis = responses.last.fetch('result')

      assert !diagnosis['isError'] && diagnosis.dig('content', 0, 'text').include?('effect.outcome_unknown')
    end
  end

  def test_tool_errors_redact_secret_shaped_arguments
    with_server do |server|
      secret = "sk-#{'z' * 32}"
      result = rpc(server, 'tools/call', name: 'explain_turn', arguments: { thread_id: secret })

      assert result.dig(:result, :isError)
      refute_includes result.dig(:result, :content, 0, :text), secret
    end
  end

  private

  def stdio_call(directory)
    command = [RbConfig.ruby, *SUBPROCESS_LIB_ARGS, ROOT.join('gems/tamoz-agent-cli/exe/tamoz').to_s,
               '--runtime-dir', directory, 'self-observe']
    out, _err, status = Open3.capture3(*command, stdin_data: stdio_requests)
    [out.lines.map { |line| JSON.parse(line) }, status]
  end

  def stdio_requests
    messages = [
      { jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } } },
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'diagnose', arguments: {} } }
    ]
    "#{messages.map { |request| JSON.generate(request) }.join("\n")}\n"
  end

  def with_server
    with_runtime do |directory|
      server = Tamoz::Agent::SelfObserveServer.new(runtime_dir: directory, session_dir: nil).mcp_server
      rpc(server, 'initialize', protocolVersion: '2025-06-18', capabilities: {},
                                clientInfo: { name: 'test', version: '1' })
      yield server
    end
  end

  def with_runtime
    Dir.mktmpdir('tamoz-self-observe') do |directory|
      File.chmod(0o700, directory)
      DurableRecordBuilder.open(File.join(directory, 'runtime.sqlite3')) do |builder|
        turn = builder.completed_turn(thread: 'thread.a')
        builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'tool.mcp.write',
                       outcome: :unknown,
                       error: { 'class' => 'Tamoz::MCP::TransportError', 'message' => 'timeout' })
      end
      yield directory
    end
  end

  def rpc(server, method, **params)
    request = { jsonrpc: '2.0', id: SecureRandom.hex(4), method: }
    request[:params] = params unless params.empty?
    JSON.parse(server.handle_json(JSON.generate(request)), symbolize_names: true)
  end
end
