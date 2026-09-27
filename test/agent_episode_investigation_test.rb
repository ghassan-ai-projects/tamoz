# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/stream/decision_node_builder'

# Plumbing only: the frame, budget and tool-node mechanics of investigate-then-decide.
# Nothing here calls a model or says anything about one.
class AgentEpisodeInvestigationTest < Minitest::Test
  Agent = Tamoz::Agent
  CATALOG = [{ 'code' => 'low_oxygen', 'description' => 'Oxygen below threshold.' },
             { 'code' => 'unknown', 'description' => 'Cannot tell.' }].freeze
  SNAPSHOT = { 'facts' => { 'do_mg_l' => 3.1, 'temp_c' => 24 } }.freeze
  NO_TOOLS_DIGEST = 'sha256:ebe8e5402a27556abf229e20c3e0bf184ddaf56403c26afa7822e6e77fd55de3'
  SURFACE = [{ 'name' => 'probe_logs_search', 'description' => 'Search the pond logs.',
               'parameters' => { 'type' => 'object', 'properties' => { 'filter' => { 'type' => 'string' } } } }].freeze

  Outcome = Struct.new(:projection, :status) do
    def unknown? = status == :unknown
    def failed? = status == :failed
  end

  class RecordingToolCall
    attr_reader :calls

    def initialize = @calls = []

    def call(slot:, tool_name:, arguments:, **)
      @calls << [slot, tool_name, arguments]
      Outcome.new({ 'tool' => tool_name, 'is_error' => false, 'result_json' => "ok #{slot}",
                    'result_bytes' => 4, 'slot' => slot }, :succeeded)
    end
  end

  def builder
    Agent::EpisodeFrameBuilder.new(catalog: Agent::DiagnosisCatalog.from_list(CATALOG),
                                   objective: 'Keep the pond safe.')
  end

  def frame(**extras) = builder.build(snapshot: SNAPSHOT, prompt: 'Diagnose.', prompt_version: '1', **extras)

  def test_an_episode_without_tools_keeps_the_frame_bytes_it_had_before_investigation
    assert_equal NO_TOOLS_DIGEST, frame.digest
  end

  def test_the_tool_surface_is_rendered_in_the_system_section_only_when_present
    with_tools = frame(tooling: tooling(final: false))

    assert_includes with_tools.system, '- probe_logs_search: Search the pond logs.'
    assert_includes with_tools.system, 'allows 3 tool calls'
    assert_includes with_tools.system, 'evidence_gaps'
    refute_includes frame.system, 'TOOLS:'
  end

  def test_results_are_fenced_data_and_only_successful_results_are_citable
    long = 'x' * (Agent::EpisodeFrameBuilder::MAX_TOOL_RESULT_BYTES + 10)
    results = [
      { 'tool' => 'probe_logs_search', 'purpose' => 'oxygen trend', 'is_error' => false, 'result_json' => long },
      { 'tool' => 'probe_logs_search', 'is_error' => true, 'error_code' => 'budget_spent', 'result_json' => 'not run' }
    ]
    built = frame(tooling: tooling(final: false), tool_results: results)
    entries = JSON.parse(built.user).fetch('tool_results')

    refute_includes built.system, long[0, 100]
    assert_equal 'oxygen trend', entries.first.fetch('purpose')
    assert entries.first.fetch('truncated')
    assert_equal Agent::EpisodeFrameBuilder::MAX_TOOL_RESULT_BYTES, entries.first.fetch('result').bytesize
    assert_includes built.evidence_ids, 'tool:0'
    refute_includes built.evidence_ids, 'tool:1'
  end

  def test_the_budget_names_the_final_call_and_the_spent_call
    budget = Agent::ReceiptBudgetController.new({ 'max_tool_calls' => 2, 'max_model_calls' => 3 })
    fresh = nil
    one_model_left = { 'model_calls_used' => 2, 'tool_calls_used' => 1 }
    no_tools_left = { 'model_calls_used' => 1, 'tool_calls_used' => 2 }

    refute budget.final_call?(fresh)
    assert budget.final_call?(one_model_left)
    assert budget.final_call?(no_tools_left)
    refute budget.spent?(one_model_left)
    assert budget.spent?({ 'model_calls_used' => 3, 'tool_calls_used' => 0 })
    assert budget.spent?(no_tools_left)
    assert_equal 8, Agent::ReceiptBudgetController.new(nil).tool_limit
  end

  def test_every_request_runs_in_order_and_requests_past_the_budget_are_recorded_not_run
    tool_call = RecordingToolCall.new
    nodes = nodes_with(tool_call)
    requests = %w[a b c d].map do |filter|
      { 'name' => 'probe_logs_search', 'arguments' => { 'filter' => filter }, 'purpose' => filter }
    end
    requests[1] = requests[1].merge('name' => 'probe_invented')
    state = tool_state(requests, budget: { 'max_tool_calls' => 3 })
    state[:tool_results] = [{ 'tool' => 'earlier' }]
    state[:budget_state] = { 'tool_calls_used' => 1 }
    update = nodes.execute_tool(state, nil)
    results = update.fetch('tool_results')

    assert_equal [[1, 'probe_logs_search', { 'filter' => 'a' }], [3, 'probe_logs_search', { 'filter' => 'c' }]],
                 tool_call.calls
    assert_equal(%w[a b c d], results.map { |result| result.fetch('purpose') })
    assert_equal(%w[not_granted budget_spent], [results[1], results[3]].map { |result| result.fetch('error_code') })
    assert_equal([false, false], [results[1], results[3]].map { |result| result.fetch('dispatched') })
    assert_equal 3, update.fetch('budget_state').fetch('tool_calls_used')
  end

  def test_the_final_directive_joins_the_frame_when_the_next_call_is_the_last
    nodes = nodes_with(RecordingToolCall.new)
    tool_frame = nodes.send(:tool_frame, { wire: { 'tool_surface' => SURFACE, 'budget' => { 'max_tool_calls' => 1 } },
                                           budget_state: { 'tool_calls_used' => 1 } })

    assert tool_frame.fetch(:tooling).final
    user = JSON.parse(frame(**tool_frame).user)

    assert_includes user.fetch('budget_directive'), 'FINAL CALL'
    refute user.key?('repair_directive')
    assert_empty nodes.send(:tool_frame, { wire: { 'budget' => { 'max_tool_calls' => 1 } }, budget_state: nil })
  end

  def test_a_host_tool_error_is_journaled_as_an_error_result_not_a_failure
    host = Object.new
    def host.execute(_name, _arguments, context:) = raise(Tamoz::Core::ToolError, "unknown tool probe_x #{context}")
    projection = Agent::EpisodeToolCall.new(tool_port: host)
                                       .send(:execute_tool, host, { tool_name: 'probe_x', arguments: {} }, 'ctx')

    assert projection.fetch('is_error')
    assert_equal 'tool_error', projection.fetch('error_code')
    assert_equal 'unknown tool probe_x ctx', projection.fetch('result_json')
  end

  def test_cancellation_and_deadlines_are_not_turned_into_tool_results
    [Tamoz::CancelledError, Tamoz::TimeoutError].each do |error|
      host = Object.new
      host.define_singleton_method(:execute) { |*, **| raise error, 'stopped' }

      assert_raises(error) do
        Agent::EpisodeToolCall.new(tool_port: host).send(:execute_tool, host, { tool_name: 'x', arguments: {} }, nil)
      end
    end
  end

  def test_a_hash_result_is_journaled_as_json_text
    host = Object.new
    def host.execute(*, **) = { 'json' => { 'value' => 1.1 } }
    projection = Agent::EpisodeToolCall.new(tool_port: host)
                                       .send(:execute_tool, host, { tool_name: 'evidence.get', arguments: {} }, nil)

    assert_equal '{"value":1.1}', projection.fetch('result_json')
  end

  def test_the_decision_summary_names_the_gaps_and_stays_valid_utf8_when_cut
    gaps = Array.new(8) { |index| { 'datum' => "é#{index}" * 200, 'why' => 'decides it' } }
    summary = Tamoz::Stream::DecisionNodeBuilder.new.send(:summary, { 'selected_code' => 'unknown',
                                                                      'raw_confidence' => 0.6,
                                                                      'evidence_gaps' => gaps })
    decision, = Tamoz::Stream::DecisionBuilder.build_decision(
      intents: [], summary:, snapshot_digest: 'sha256:x',
      episode: { 'episode_id' => 'e1', 'attempt_id' => 'a1', 'fence' => 1 },
      snapshot: { 'situation_id' => 's1', 'situation_version' => 1 }
    )

    assert summary.start_with?('selected unknown at confidence 0.6; missing: é0')
    assert_predicate decision.fetch('summary'), :valid_encoding?
    assert_operator decision.fetch('summary').bytesize, :<=, Tamoz::Stream::DecisionBuilder::MAX_SUMMARY_BYTES
  end

  private

  def nodes_with(tool_call)
    Agent::EpisodeNodes.new(profile: nil, frame_builder_factory: nil, model_call_factory: nil,
                            decision_builder: nil, tool_call:)
  end

  def tooling(final:) = Agent::EpisodeFrameBuilder::Tooling.new(tools: SURFACE, budget: 3, final:)

  def tool_state(requests, budget:)
    catalog = Tamoz::Core.jcs([{ 'name' => 'probe_logs_search' }])
    { document: { 'tool_requests' => requests }, episode: { 'episode_id' => 'e1' },
      wire: { 'tool_catalog_json' => catalog, 'budget' => budget }, budget_state: nil, tool_results: [] }
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
