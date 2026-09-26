# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions

require_relative 'test_helper'

class AgentProbeCatalogTest < Minitest::Test
  SERVERS = { 'logs' => { 'read_only_tools' => ['query'] }, 'ops' => { 'read_only_tools' => [] },
              'db' => { 'read_only_tools' => ['query'], 'database' => true } }.freeze

  def settings(**overrides)
    {
      'targets' => { 'motor-1' => { 'stream' => 'app=motor' } },
      'probes' => [probe(**overrides)]
    }
  end

  def probe(**overrides)
    {
      'name' => 'probe_logs_search',
      'description' => 'Search the entity logs.',
      'backing' => { 'server' => 'logs', 'tool' => 'query' },
      'arguments' => { 'selector' => '{target.stream}', 'from' => '{window.from}',
                       'filter' => { 'free' => 'string', 'max_bytes' => 64 } }
    }.merge(overrides.transform_keys(&:to_s))
  end

  def load(raw = settings) = Tamoz::Agent::ProbeCatalog.new(raw, servers: SERVERS)

  def assert_refused(pattern, raw)
    error = assert_raises(Tamoz::Agent::ProbeCatalog::Error) { load(raw) }
    assert_match pattern, error.message
  end

  def test_loads_a_governed_probe_and_digests_it
    catalog = load
    probe = catalog.probe('probe_logs_search')

    assert_equal 'mcp:logs/query', probe.backing_id
    assert_equal({ 'filter' => { 'free' => 'string', 'max_bytes' => 64 } }, probe.free)
    assert_equal ['logs'], catalog.backing_servers
    assert_predicate probe, :targeted?
    assert_predicate probe, :windowed?
    assert Tamoz::Core.valid_digest?(catalog.digest)
  end

  def test_a_backing_tool_the_operator_did_not_declare_read_only_never_loads
    assert_refused(/not declared read-only/, settings(backing: { 'server' => 'ops', 'tool' => 'query' }))
    assert_refused(/not configured/, settings(backing: { 'server' => 'absent', 'tool' => 'query' }))
  end

  def test_names_free_types_placeholders_and_duplicates_are_checked
    assert_refused(/must match/, settings(name: 'probe.logs.search'))
    assert_refused(/must match/, settings(name: 'logs_search'))
    assert_refused(/unknown free type/, settings(arguments: { 'q' => { 'free' => 'shell' } }))
    assert_refused(/not a target field or window bound/, settings(arguments: { 'q' => '{target.password}' }))
    assert_refused(/not a target field or window bound/, settings(arguments: { 'q' => '{window.now}' }))
    assert_refused(/declared twice/, settings.merge('probes' => [probe, probe]))
    assert_refused(/reserved/, settings(arguments: { 'target' => { 'free' => 'string', 'max_bytes' => 8 } }))
    assert_refused(/neither a pinned value nor a free slot/, settings(arguments: { 'q' => [1] }))
  end

  def test_a_target_placeholder_needs_declared_targets
    assert_refused(/not a target field/, settings.merge('targets' => {}))
  end

  def test_a_database_server_probe_may_only_take_a_sql_select_query
    db = { 'server' => 'db', 'tool' => 'query' }
    query = { 'query' => { 'free' => 'sql_select', 'max_bytes' => 512 } }

    assert load(settings(backing: db, arguments: query)).probe('probe_logs_search')
    assert_refused(/only argument must be a sql_select slot named query/,
                   settings(backing: db, arguments: query.merge('schema' => 'ops')))
    assert_refused(/only argument must be a sql_select slot named query/,
                   settings(backing: db, arguments: { 'query' => { 'free' => 'string', 'max_bytes' => 9 } }))
  end

  def test_the_digest_binds_every_pinned_value
    changed = settings(arguments: probe.fetch('arguments').merge('selector' => '{target.stream} | x'))

    refute_equal load.digest, load(changed).digest
  end

  def test_free_slot_bounds_are_mandatory
    assert_refused(/max_bytes/, settings(arguments: { 'q' => { 'free' => 'string' } }))
    assert_refused(/min <= max/, settings(arguments: { 'n' => { 'free' => 'integer', 'min' => 5, 'max' => 1 } }))
    assert_refused(/distinct string values/, settings(arguments: { 'c' => { 'free' => 'enum', 'values' => [] } }))
  end

  def test_session_schema_offers_target_and_lookback_but_the_episode_schema_does_not
    probe = load.probe('probe_logs_search')
    session = probe.session_schema(['motor-1'])
    episode = probe.episode_schema

    assert_equal %w[filter target lookback_minutes], session.fetch('properties').keys
    assert_equal ['motor-1'], session.dig('properties', 'target', 'enum')
    assert_equal %w[filter], episode.fetch('properties').keys
    refute episode.fetch('additionalProperties')
  end
end
# rubocop:enable Minitest/MultipleAssertions
