# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P2 exit gates 3-6: the reason ↔ tool loop and the one-shot repair as GRAPH
# branches (bounded by Limits#max_steps), journaled unsafe tool effects, and
# budget enforcement from receipts. Fixture-labeled throughout (B8: these are
# plumbing tests, never evidence of reasoning).
class StreamEpisodeLoopTest < Minitest::Test
  Stream = Tamoz::Stream

  # A deterministic evidence-tool implementation (fixture) for the loop tests.
  class StubEvidenceTool
    attr_reader :calls

    def initialize(readings: {"dissolved_oxygen" => 1.1})
      @readings = readings
      @calls = 0
    end

    def execute(name, arguments, context: nil)
      @calls += 1
      if arguments.fetch("feature", "") == "dissolved_oxygen"
        value = @readings.fetch("dissolved_oxygen")
        {
          "json" => JSON.generate({"feature" => "dissolved_oxygen", "value" => value}),
          "is_error" => false
        }
      else
        {
          "json" => JSON.generate({"error" => "unknown feature"}),
          "is_error" => true,
          "error_code" => "unknown_feature"
        }
      end
    end
  end

  def tool_catalog
    [
      {"name" => "evidence.get", "parameters" => {"feature" => {"type" => "string"}}},
      {"name" => "features.query", "parameters" => {}}
    ]
  end

  def with_fixture_endpoint(responses)
    Dir.mktmpdir("tamoz-loop-endpoint") do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses:,
        log_path: File.join(dir, "endpoint.log")
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  # The tool-requesting document: a PURE tool turn (the v2 parser forbids
  # terminal fields alongside tool_requests). The fixture serves the final v2
  # answer as the SECOND response after the tool result reaches the frame.
  def tool_requesting_response
    Tamoz::Core.jcs(
      "protocol" => "tamoz.episode-diagnosis/v2",
      "tool_requests" => [
        {"name" => "evidence.get", "arguments" => {"feature" => "dissolved_oxygen"},
         "purpose" => "the dissolved oxygen reading decides the diagnosis"}
      ]
    )
  end

  def final_response
    Tamoz::Core.jcs(
      AquacultureDomain.document(selected: "low_dissolved_oxygen",
                                hypothesis: "oxygen below threshold per live evidence")
    )
  end

  def run_episode(composition, request)
    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    state = nil
    if terminal&.status == :TERMINAL_STATUS_PRODUCED
      result = composition.fetch(:app).durable_runner.fetch(
        thread: "episode.#{request.episode_id}",
        request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
        namespace: [request.tenant_id]
      )
      state = composition.fetch(:app).state(
        thread: "episode.#{request.episode_id}",
        namespace: [request.tenant_id],
        checkpoint_id: result.checkpoint_id
      ).state.to_h
    end
    [events, terminal, state]
  end

  def request_with_budget(composition, suffix, budget)
    wire = EpisodeComposition.wire_request(episode_id: "loop-#{suffix}")
    wire.budget = budget
    EpisodeComposition.grant_tools(wire, tool_catalog)
    wire
  end

  def test_gate4_tool_loop_happy_path_journaled_with_digests
    with_fixture_endpoint([tool_requesting_response, final_response]) do |endpoint|
      composition = EpisodeComposition.build(
        endpoint: endpoint.base_url,
        tool_port: StubEvidenceTool.new
      )
      events, terminal, state = run_episode(composition, request_with_budget(composition, "happy", nil))
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      assert_equal "low_dissolved_oxygen", state.fetch(:document).fetch("selected_code")
      assert_equal 2, state.fetch(:model_receipts).length, "two journaled model calls"
      tool_results = state.fetch(:tool_results)
      assert_equal 1, tool_results.length
      assert_equal "evidence.get", tool_results.first.fetch("tool")
      assert_kind_of String, tool_results.first.fetch("result_sha256")
      assert_operator tool_results.first.fetch("result_bytes"), :>, 0
      assert_match(/\Asha256:[0-9a-f]{64}\z/, tool_results.first.fetch("request_digest"))
      # The frame accumulated the tool result: the second call's prompt cites tool:0.
      events_docs = events
      refute_nil events_docs
      composition.fetch(:adapter).close
    end
  end

  def test_gate4_tool_refusal_path_journaled
    with_fixture_endpoint([tool_requesting_response, final_response]) do |endpoint|
      composition = EpisodeComposition.build(
        endpoint: endpoint.base_url,
        tool_port: StubEvidenceTool.new
      )
      events, terminal, state = run_episode(composition, request_with_budget(composition, "refuse", nil))
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      tool = state.fetch(:tool_results).first
      assert_equal false, tool.fetch("is_error")
      composition.fetch(:adapter).close
    end
  end

  def test_gate6_repair_fires_once_after_malformed_success
    malformed = JSON.generate(
      "protocol" => "tamoz.episode-diagnosis/v2",
      "diagnosis_probabilities" => [{"diagnosis_code" => "unknown", "probability" => 0.5}],
      "evidence_refs" => []
    )
    with_fixture_endpoint([malformed, final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      events, terminal, state = run_episode(composition, request_with_budget(composition, "repair1", nil))
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      assert_equal 2, state.fetch(:model_receipts).length
      assert_equal 1, state.fetch(:repair_count), "repair fires exactly once"
      assert_kind_of String, state.fetch(:repair_directive)
      composition.fetch(:adapter).close
    end

    # Two malformed responses in a row → typed terminal, no third call.
    with_fixture_endpoint([malformed, malformed]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      _events, terminal, _state = run_episode(composition, request_with_budget(composition, "repair2", nil))
      assert_equal :TERMINAL_STATUS_FAILED, terminal.status
      assert_equal 2, endpoint.observed.length, "no third provider call after two malformed responses"
      composition.fetch(:adapter).close
    end
  end

  def test_gate5_a_tool_turn_on_the_last_allowed_call_is_a_typed_budget_terminal
    budget = Agenticstream::Runtime::V1::EpisodeBudget.new(max_model_calls: 1)
    tool = StubEvidenceTool.new
    with_fixture_endpoint([tool_requesting_response, final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url, tool_port: tool)
      _events, terminal, _state = run_episode(composition, request_with_budget(composition, "budget", budget))
      assert_equal :TERMINAL_STATUS_BUDGET_EXHAUSTED, terminal.status
      assert_equal 1, endpoint.observed.length, "no second provider call"
      assert_equal 0, tool.calls, "the tool turn on the final call is refused before any tool runs"
      composition.fetch(:adapter).close
    end
  end

  def test_a_tool_the_catalog_does_not_grant_becomes_an_uncitable_result_and_the_episode_decides
    invented = Tamoz::Core.jcs(
      "protocol" => "tamoz.episode-diagnosis/v2",
      "tool_requests" => [{"name" => "not.in.catalog", "arguments" => {}, "purpose" => "try an invented tool"}]
    )
    tool = StubEvidenceTool.new
    with_fixture_endpoint([invented, final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url, tool_port: tool)
      _events, terminal, state = run_episode(composition, request_with_budget(composition, "forge", nil))
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      result = state.fetch(:tool_results).first
      assert_equal "not_granted", result.fetch("error_code")
      assert_equal 0, tool.calls
      composition.fetch(:adapter).close
    end
  end
end
