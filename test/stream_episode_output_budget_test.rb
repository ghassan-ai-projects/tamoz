# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'tamoz/stream/episode_worker'
require 'support/local_model_endpoint'
require 'support/aquaculture_domain'
require 'support/episode_composition'

# An episode's output budget is sent with every model request, so the provider stops at it.
class StreamEpisodeOutputBudgetTest < Minitest::Test
  Budget = Agenticstream::Runtime::V1::EpisodeBudget

  def with_fixture_endpoint(responses)
    Dir.mktmpdir('tamoz-output-budget') do |dir|
      endpoint = LocalModelEndpoint.new(mode: :fixture, responses:, log_path: File.join(dir, 'endpoint.log')).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def final_response
    Tamoz::Core.jcs(AquacultureDomain.document(selected: 'low_dissolved_oxygen', hypothesis: 'oxygen below threshold'))
  end

  def malformed_response = JSON.generate('protocol' => 'tamoz.episode-diagnosis/v2', 'unexpected' => true)

  def truncated_reply
    message = { 'role' => 'assistant', 'content' => '{"protocol":"tamoz.ep' }
    body = JSON.generate('choices' => [{ 'index' => 0, 'finish_reason' => 'length', 'message' => message }],
                         'usage' => { 'prompt_tokens' => 42, 'completion_tokens' => 1000, 'total_tokens' => 1042 })
    { status: 200, body: }
  end

  def run_episode(composition, budget, suffix)
    request = EpisodeComposition.wire_request(episode_id: "output-budget-#{suffix}")
    request.budget = budget
    events = composition.fetch(:runner).run(request).to_a
    [events, events.filter_map(&:terminal).last]
  end

  def max_tokens_sent(endpoint) = endpoint.request_bodies.map { |body| JSON.parse(body)['max_tokens'] }

  def test_the_first_request_carries_the_whole_output_budget
    with_fixture_endpoint([final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      _events, terminal = run_episode(composition, Budget.new(max_output_tokens: 20_000), 'first')

      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      assert_equal [20_000], max_tokens_sent(endpoint)
      composition.fetch(:adapter).close
    end
  end

  def test_a_repair_request_carries_what_the_first_call_left
    with_fixture_endpoint([malformed_response, final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      _events, terminal = run_episode(composition, Budget.new(max_output_tokens: 20_000), 'repair')

      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      assert_equal [20_000, 19_979], max_tokens_sent(endpoint), 'the fixture reports 21 output tokens per call'
      composition.fetch(:adapter).close
    end
  end

  def test_no_output_budget_sends_no_max_tokens
    with_fixture_endpoint([final_response]) do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      _events, terminal = run_episode(composition, Budget.new(max_model_calls: 4), 'unbounded')

      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      assert_equal [nil], max_tokens_sent(endpoint)
      composition.fetch(:adapter).close
    end
  end

  def test_an_answer_cut_off_at_the_limit_ends_budget_exhausted
    with_fixture_endpoint([truncated_reply]) do |endpoint|
      log = StringIO.new
      composition = EpisodeComposition.build(endpoint: endpoint.base_url, log:)
      events, terminal = run_episode(composition, Budget.new(max_output_tokens: 1000), 'length')
      diagnostic = events.filter_map(&:diagnostic).last

      assert_equal :TERMINAL_STATUS_BUDGET_EXHAUSTED, terminal.status
      assert_equal ['stream_budget_exceeded', 'output token budget reached'], [diagnostic.code, diagnostic.message]
      assert_equal 1, endpoint.observed.length, 'a cut-off answer is not repaired or retried'
      composition.fetch(:adapter).close
    end
  end
end
