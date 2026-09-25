# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require 'tamoz/mcp'

class AgentProbeSourceTest < Minitest::Test
  Invocation = Tamoz::Mcp::Invocation
  PEM = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAsecretkeybodyline\n-----END RSA PRIVATE KEY-----"

  class Inner
    attr_reader :calls, :descriptors

    def initialize(text:, status: :succeeded, structured: nil)
      @text = text
      @status = status
      @structured = structured
      @calls = []
      @descriptors = [descriptor('logs', 'query'), descriptor('logs', 'delete_all'), descriptor('web', 'fetch')]
    end

    def name?(name) = @descriptors.any? { |descriptor| descriptor.id == name }
    def read_only?(name) = %w[mcp:logs/query mcp:web/fetch].include?(name)
    def mcp_source_digests = { 'logs' => 'sha256:x' }
    def validate(_name, arguments) = arguments
    def preview(name, _arguments) = "MCP #{name}"
    def effect_intent(_name, _arguments) = {}
    def maximum_effect_output_bytes(_name) = 65_536

    def execute(_context, name, arguments)
      @calls << [name, arguments]
      observation = if @status == :succeeded
                      Invocation::Observation.new(server_id: 'logs', content_blocks: [], text: @text,
                                                  structured_content: @structured, truncated: false)
                    end
      Invocation::Outcome.new(status: @status, observation:, interrupt: nil, denial: nil, effect_key: 'k')
    end

    private

    def descriptor(server, tool)
      Invocation::Descriptor.new(id: "mcp:#{server}/#{tool}", name: tool, source_id: server,
                                 definition_digest: 'sha256:d', input_schema: {}, output_schema: nil,
                                 effect_class: :read_only, protocol_profile: 'p')
    end
  end

  NOW = Time.utc(2026, 9, 25, 12, 0, 0)

  def catalog(max_result_bytes: 1024, target: { 'stream' => 'app=motor', 'unit' => 'motor-controller' })
    Tamoz::Agent::ProbeCatalog.new(
      {
        'targets' => { 'motor-1' => target },
        'probes' => [
          { 'name' => 'probe_logs_search', 'description' => 'Search logs.',
            'backing' => { 'server' => 'logs', 'tool' => 'query' }, 'max_result_bytes' => max_result_bytes,
            'arguments' => { 'selector' => '{target.stream}', 'from' => '{window.from}', 'until' => '{window.until}',
                             'filter' => { 'free' => 'string', 'max_bytes' => 16 },
                             'limit' => { 'free' => 'integer', 'min' => 1, 'max' => 50 } } },
          { 'name' => 'probe_db_select', 'description' => 'Read rows.',
            'backing' => { 'server' => 'logs', 'tool' => 'query' },
            'arguments' => { 'query' => { 'free' => 'sql_select', 'max_bytes' => 256 } } },
          { 'name' => 'probe_unit_status', 'description' => 'Unit status.',
            'backing' => { 'server' => 'logs', 'tool' => 'query' },
            'arguments' => { 'argv' => { 'free' => 'enum',
                                         'values' => ['systemctl status {target.unit}', 'uptime'] } } }
        ]
      },
      servers: { 'logs' => { 'read_only_tools' => ['query'] } }
    )
  end

  def source(text: 'motor-1 overheated', status: :succeeded, structured: nil, **)
    @inner = Inner.new(text:, status:, structured:)
    Tamoz::Agent::ProbeSource.new(source: @inner, catalog: catalog(**), clock: -> { NOW })
  end

  def session_arguments = { 'filter' => 'temp', 'limit' => 5, 'target' => 'motor-1', 'lookback_minutes' => 30 }
  def window = { 'from' => '2026-09-25T00:00:00Z', 'until' => '2026-09-25T01:00:00Z' }

  def test_backing_server_tools_are_replaced_by_probes_and_other_servers_stay
    probes = source

    assert_equal %w[mcp:web/fetch probe_logs_search probe_db_select probe_unit_status], probes.names
    assert probes.probe?('probe_logs_search')
    %w[mcp:logs/delete_all mcp:logs/query].each do |hidden|
      assert_raises(Tamoz::Agent::ToolError) { probes.execute(nil, hidden, {}) }
      assert_raises(Tamoz::Agent::ToolError) { probes.validate(hidden, {}) }
      assert_raises(Tamoz::Agent::ToolError) { probes.preview(hidden, {}) }
      assert_raises(Tamoz::Agent::ToolError) { probes.maximum_effect_output_bytes(hidden) }
      assert_raises(Tamoz::Agent::ToolError) { probes.read_only?(hidden) }
    end
    assert_empty @inner.calls
    refute_respond_to probes, :__getobj__
    assert_includes probes.mcp_source_digests.keys, 'probes:catalog'
  end

  def test_session_call_resolves_pinned_scope_and_runs_only_the_backing_tool
    probes = source
    outcome = probes.execute(nil, 'probe_logs_search', session_arguments)

    assert_equal 'motor-1 overheated', outcome.observation.text
    name, arguments = @inner.calls.fetch(0)

    assert_equal 'mcp:logs/query', name
    assert_equal({ 'selector' => 'app=motor', 'from' => '2026-09-25T11:30:00Z', 'until' => '2026-09-25T12:00:00Z',
                   'filter' => 'temp', 'limit' => 5 }, arguments)
  end

  def test_a_pinned_unknown_or_missing_argument_from_the_model_is_refused_never_merged
    probes = source

    %w[selector from shell].each do |key|
      error = assert_raises(Tamoz::Agent::ToolArgumentError) do
        probes.execute(nil, 'probe_logs_search', session_arguments.merge(key => 'x'))
      end
      assert_match(/does not accept/, error.message)
    end
    error = assert_raises(Tamoz::Agent::ToolArgumentError) do
      probes.execute(nil, 'probe_logs_search', session_arguments.except('filter'))
    end
    assert_match(/needs filter/, error.message)
    assert_empty @inner.calls
  end

  def test_templates_fill_once_and_only_in_pinned_values_and_chosen_enum_values
    probes = source(target: { 'stream' => '{window.from}', 'unit' => 'motor-controller' })
    probes.execute(nil, 'probe_logs_search', session_arguments.merge('filter' => '{target.unit}'))
    probes.execute(nil, 'probe_unit_status', { 'argv' => 'systemctl status {target.unit}', 'target' => 'motor-1' })
    logs, status = @inner.calls.map(&:last)

    assert_equal '{window.from}', logs.fetch('selector')
    assert_equal '{target.unit}', logs.fetch('filter')
    assert_equal({ 'argv' => 'systemctl status motor-controller' }, status)
  end

  def test_free_slots_are_bounded
    probes = source
    bad = [{ 'filter' => 'x' * 17 }, { 'filter' => 'é' * 9 }, { 'limit' => 51 }, { 'limit' => 0 }, { 'limit' => '5' },
           { 'target' => 'motor-2' }, { 'lookback_minutes' => 0 }, { 'lookback_minutes' => 1441 }]

    bad.each do |override|
      assert_raises(Tamoz::Agent::ToolArgumentError, override.inspect) do
        probes.validate('probe_logs_search', session_arguments.merge(override))
      end
    end
    assert_raises(Tamoz::Agent::ToolArgumentError) do
      probes.validate('probe_unit_status', { 'argv' => 'rm -rf /', 'target' => 'motor-1' })
    end
    ['DELETE FROM motors', 'SELECT 1; SELECT 2'].each do |query|
      assert_raises(Tamoz::Agent::ToolArgumentError) { probes.execute(nil, 'probe_db_select', { 'query' => query }) }
    end
    probes.execute(nil, 'probe_db_select', { 'query' => 'SELECT 1' })

    assert_equal [['mcp:logs/query', { 'query' => 'SELECT 1' }]], @inner.calls
  end

  def test_results_are_scrubbed_including_key_bodies_then_capped_within_the_declared_bound
    probes = source(text: "token sk-abcdefghijklmnop #{PEM} #{'y' * 400}", max_result_bytes: 256)
    observation = probes.execute(nil, 'probe_logs_search', session_arguments).observation

    refute_includes observation.text, 'sk-abcdefghijklmnop'
    refute_includes observation.text, 'secretkeybodyline'
    assert observation.truncated
    assert observation.text.end_with?('[truncated]')
    assert_operator observation.text.bytesize, :<=, 256
    refute_includes JSON.generate(observation.content_blocks), 'secretkeybodyline'
  end

  def test_structured_only_results_become_scrubbed_text
    probes = source(text: '', structured: { 'status' => 'failed', 'token' => 'sk-abcdefghijklmnop' })
    text = probes.execute(nil, 'probe_logs_search', session_arguments).observation.text

    assert_includes text, '"status":"failed"'
    refute_includes text, 'sk-abcdefghijklmnop'
  end

  def test_episode_scope_comes_from_the_snapshot_and_refusals_are_results
    probes = source
    tools = probes.episode_tools(entity_id: 'motor-1', window:)
    result = tools.fetch('probe_logs_search').call({ 'filter' => 'temp', 'limit' => 3 }, {})

    assert_equal({ 'json' => 'motor-1 overheated', 'truncated' => false, 'result_bytes' => 18 }, result)
    assert_equal 'app=motor', @inner.calls.fetch(0).fetch(1).fetch('selector')

    refused = tools.fetch('probe_logs_search').call({ 'filter' => 'temp', 'limit' => 3, 'target' => 'motor-1' }, {})

    assert_equal 'argument_not_free', refused.fetch('error_code')
    unknown = probes.episode_tools(entity_id: 'pump-9', window:)
                    .fetch('probe_logs_search').call({ 'filter' => 'temp', 'limit' => 3 }, {})

    assert_equal 'scope_unresolved', unknown.fetch('error_code')
    assert_equal 1, @inner.calls.length
  end

  def test_an_episode_probe_whose_call_does_not_succeed_returns_an_error_result
    %i[denied interrupt].each do |status|
      result = source(status:).episode_tools(entity_id: 'motor-1', window:)
                              .fetch('probe_db_select').call({ 'query' => 'SELECT 1' }, {})

      assert result.fetch('is_error'), "#{status} is an error result"
      assert_equal 'probe_failed', result.fetch('error_code')
    end
  end

  def test_a_probe_whose_backing_tool_the_server_does_not_offer_never_loads
    inner = Inner.new(text: '')
    def inner.read_only?(_name) = false
    error = assert_raises(Tamoz::Agent::ProbeCatalog::Error) do
      Tamoz::Agent::ProbeSource.new(source: inner, catalog: catalog)
    end
    assert_match(/does not offer/, error.message)
  end

  def test_probe_tools_describe_each_mode
    probes = source
    session = probes.session_tools.first
    episode = probes.episode_surface.first

    assert_equal 'probe_logs_search', session.fetch('name')
    assert_includes session.dig('parameters', 'properties').keys, 'target'
    refute_includes episode.dig('parameters', 'properties').keys, 'target'
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
