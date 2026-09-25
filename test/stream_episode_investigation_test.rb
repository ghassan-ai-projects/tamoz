# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'tamoz/stream/episode_worker'
require 'support/local_model_endpoint'
require 'support/aquaculture_domain'
require 'support/episode_composition'
require 'support/probe_fixture'

# The investigate-then-decide loop through the real runner, graph, journal and capability host, with a
# scripted model endpoint and a stand-in MCP server. Plumbing only — never evidence that a model reasons.
class StreamEpisodeInvestigationTest < Minitest::Test
  V1 = Agenticstream::Runtime::V1
  LOG_LINE = '02:10 aerator-2 tripped: motor overcurrent; dissolved oxygen falling'

  def teardown
    @endpoint&.stop
    @composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(@endpoint_dir) if @endpoint_dir
  end

  def compose(responses, answers: [LOG_LINE])
    @endpoint_dir = Dir.mktmpdir('tamoz-investigation')
    @endpoint = LocalModelEndpoint.new(mode: :fixture, responses:,
                                       log_path: File.join(@endpoint_dir, 'endpoint.log')).start
    @probes, @server = ProbeFixture.source(answers)
    @composition = EpisodeComposition.build(endpoint: @endpoint.base_url, probe_source: @probes)
  end

  def request(suffix, budget: nil, catalog: [{ 'name' => 'probe_pond_log' }], fence: 1)
    wire = EpisodeComposition.wire_request(episode_id: "inv-#{suffix}", fence:)
    EpisodeComposition.grant_tools(wire, catalog)
    wire.budget = budget
    wire.evidence_time_range = V1::EvidenceTimeRange.new(
      from: Google::Protobuf::Timestamp.new(seconds: 1_786_000_000),
      until: Google::Protobuf::Timestamp.new(seconds: 1_786_003_600)
    )
    wire
  end

  def run_episode(wire, runner: @composition.fetch(:runner))
    events = runner.run(wire).to_a
    terminal = events.filter_map(&:terminal).last
    [events, terminal, terminal_state(wire)]
  end

  def terminal_state(wire)
    app = @composition.fetch(:app)
    thread = "episode.#{wire.episode_id}"
    result = app.durable_runner.fetch(thread:, namespace: [wire.tenant_id],
                                      request_id: "#{thread}.#{wire.attempt_id}.#{wire.fence}")
    return {} unless result&.checkpoint_id

    app.state(thread:, namespace: [wire.tenant_id], checkpoint_id: result.checkpoint_id).state.to_h
  end

  def tool_turn(*filters)
    Tamoz::Core.jcs(
      'protocol' => 'tamoz.episode-diagnosis/v2',
      'tool_requests' => filters.map do |filter|
        { 'name' => 'probe_pond_log', 'arguments' => { 'filter' => filter }, 'purpose' => 'is the aerator running?' }
      end
    )
  end

  def decision(selected: 'equipment_failure', refs: ['tool:0'], gaps: nil)
    document = AquacultureDomain.document(selected:, hypothesis: 'aerator tripped')
    document['evidence_refs'] = refs
    document['evidence_gaps'] = gaps if gaps
    Tamoz::Core.jcs(document)
  end

  def frame_user(state) = JSON.parse(state.fetch(:frame).fetch('user'))

  def test_insufficient_snapshot_then_a_probe_then_a_decision_citing_it
    compose([tool_turn('aerator'), decision])
    events, terminal, state = run_episode(request('happy'))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_includes state.fetch(:frame).fetch('system'), '- probe_pond_log: Search the pond controller log.'
    entry = frame_user(state).fetch('tool_results').first

    assert_equal LOG_LINE, entry.fetch('result')
    assert_equal 'is the aerator running?', entry.fetch('purpose')
    assert_equal ['mcp:logs/query', { 'selector' => 'pond=07', 'from' => '2026-08-06T07:06:40Z',
                                      'until' => '2026-08-06T08:06:40Z', 'filter' => 'aerator' }], @server.calls.first
    assert_equal ['tool:0'], state.fetch(:document).fetch('evidence_refs')
    tools = events.filter_map(&:tool)

    assert_equal([['probe_pond_log', true]], tools.map { |tool| [tool.tool_name, tool.execution_started] })
    assert_equal 1, events.filter_map(&:budget).last.tool_calls_used
  end

  def test_a_spent_tool_budget_gets_the_final_directive_and_an_honest_abstain
    gaps = [{ 'datum' => 'aerator-2 current draw', 'why' => 'separates a trip from a sensor fault' }]
    compose([tool_turn('aerator'), decision(selected: 'unknown', refs: ['tool:0'], gaps:)])
    _events, terminal, state = run_episode(request('spent', budget: V1::EpisodeBudget.new(max_tool_calls: 1)))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_includes frame_user(state).fetch('budget_directive'), 'FINAL CALL'
    assert_equal 'unknown', state.fetch(:document).fetch('selected_code')
    assert_includes state.fetch(:decision).fetch('summary'), 'missing: aerator-2 current draw'
  end

  def test_requests_past_the_budget_are_neither_reported_nor_counted
    compose([tool_turn('a', 'b'), decision])
    events, terminal, state = run_episode(request('counted', budget: V1::EpisodeBudget.new(max_tool_calls: 1)))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal(%w[budget_spent], state.fetch(:tool_results).filter_map { |result| result['error_code'] })
    assert_equal 1, events.filter_map(&:tool).length
    assert_equal 1, events.filter_map(&:budget).last.tool_calls_used
  end

  def test_a_catalog_that_does_not_match_its_digest_is_refused_before_anything_runs
    compose([tool_turn('aerator'), decision])
    wire = request('forged')
    wire.tool_catalog_json = Tamoz::Core.jcs([{ 'name' => 'probe_pond_log' }, { 'name' => 'probe_extra' }])
    _events, terminal, = run_episode(wire)

    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
    assert_empty @server.calls
    assert_equal 0, @endpoint.observed.length
  end

  def test_a_missing_or_partial_time_range_makes_window_probes_refuse
    compose([decision])
    runner = @composition.fetch(:runner)
    stamp = ->(seconds) { Google::Protobuf::Timestamp.new(seconds:) }

    assert_nil runner.send(:evidence_range, nil)
    assert_nil runner.send(:evidence_range, V1::EvidenceTimeRange.new(until: stamp.call(1_786_003_600)))
    assert_nil runner.send(:evidence_range, V1::EvidenceTimeRange.new(from: stamp.call(9), until: stamp.call(5)))
    compose([tool_turn('aerator'), decision(selected: 'unknown', refs: ['fact:pond_id'])])
    wire = request('no-window')
    wire.evidence_time_range = nil
    _events, terminal, state = run_episode(wire)

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal 'scope_unresolved', state.fetch(:tool_results).first.fetch('error_code')
    assert_empty @server.calls
  end

  def test_the_model_budget_running_out_first_also_gets_the_final_directive
    compose([tool_turn('aerator'), decision])
    _events, terminal, state = run_episode(request('models', budget: V1::EpisodeBudget.new(max_model_calls: 2)))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_includes frame_user(state).fetch('budget_directive'), 'FINAL CALL'
  end

  def test_a_failed_probe_is_an_error_entry_and_the_episode_still_decides
    compose([tool_turn('aerator'), decision(selected: 'unknown', refs: ['fact:pond_id'])],
            answers: [Tamoz::Agent::ToolError])
    _events, terminal, state = run_episode(request('failed'))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    result = state.fetch(:tool_results).first

    assert result.fetch('is_error')
    assert_equal 'probe_failed', result.fetch('error_code')
  end

  def test_citing_a_failed_probe_is_refused
    compose([tool_turn('aerator'), decision(refs: ['tool:0']), decision(refs: ['tool:0'])],
            answers: [Tamoz::Agent::ToolError])
    _events, terminal, _state = run_episode(request('cite-failed'))

    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
  end

  def test_three_requests_run_as_three_journaled_slots_in_order
    compose([tool_turn('a', 'b', 'c'), decision])
    events, terminal, state = run_episode(request('three'))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal([0, 1, 2], state.fetch(:tool_results).map { |result| result.fetch('slot') })
    assert_equal(%w[a b c], @server.calls.map { |_name, arguments| arguments.fetch('filter') })
    assert_equal 3, events.filter_map(&:tool).length
  end

  def test_a_crash_between_slots_replays_the_done_slot_and_re_reads_the_interrupted_one
    compose([tool_turn('a', 'b', 'c'), decision], answers: ['first', Tamoz::TimeoutError, 'second', 'third'])
    _events, crashed, = run_episode(request('crash', fence: 1))

    assert_equal :TERMINAL_STATUS_TIMED_OUT, crashed.status
    _events, terminal, state = run_episode(request('crash', fence: 2))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal %w[a b b c], @server.calls.map { |_name, arguments| arguments.fetch('filter') },
                 'slot 0 replays from the journal; slot 1 is re-read; slot 2 runs once'
    assert_equal(%w[first second third], state.fetch(:tool_results).map { |result| result.fetch('result_json') })
  end

  def test_a_probe_the_wire_catalog_does_not_grant_is_never_run
    compose([tool_turn('aerator'), decision(selected: 'unknown', refs: ['fact:pond_id'])])
    _events, terminal, state = run_episode(request('ungranted', catalog: [{ 'name' => 'evidence_get' }]))

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal 'not_granted', state.fetch(:tool_results).first.fetch('error_code')
    assert_empty @server.calls
    refute_includes state.fetch(:frame).fetch('system'), 'probe_pond_log'
  end

  def test_the_surface_reads_go_spelled_catalogs_and_keeps_stream_tools_only_with_an_evidence_channel
    compose([decision])
    runner = @composition.fetch(:runner)
    catalog = [{ 'name' => 'evidence_get', 'description' => 'Read one evidence series.',
                 'schema' => { 'type' => 'object' } },
               { 'name' => 'probe_pond_log', 'description' => 'generic', 'schema' => {} }]
    closed = request('surface', catalog:)
    open = request('surface', catalog:)
    open.evidence_tools_endpoint = 'unix:///tmp/evidence.sock'
    open.capability_token = 'token'

    assert_equal(%w[probe_pond_log], runner.send(:tool_surface, closed).map { |tool| tool.fetch('name') })
    surface = runner.send(:tool_surface, open)

    assert_equal(%w[evidence_get probe_pond_log], surface.map { |tool| tool.fetch('name') })
    assert_equal 'Read one evidence series.', surface.first.fetch('description')
    assert_equal 'Search the pond controller log.', surface.last.fetch('description')
  end

  def test_a_redelivery_is_idempotent_and_a_changed_catalog_is_refused
    compose([tool_turn('aerator'), decision])
    wire = request('redeliver')
    _events, first, = run_episode(wire)
    _events, again, = run_episode(wire)

    assert_equal :TERMINAL_STATUS_PRODUCED, first.status
    assert_equal :TERMINAL_STATUS_PRODUCED, again.status
    changed = ProbeFixture::SETTINGS.merge('targets' => { 'pond-07' => { 'stream' => 'pond=07b' } })
    other, = ProbeFixture.source([LOG_LINE], settings: changed)
    runner = Tamoz::Stream::EpisodeRunner.new(durable_runner: @composition.fetch(:app).durable_runner,
                                              worker: @composition.fetch(:runner).worker, probe_source: other)
    _events, refused, = run_episode(wire, runner:)

    assert_equal :TERMINAL_STATUS_FAILED, refused.status
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
