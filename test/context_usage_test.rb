# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextUsageTest < Minitest::Test
  include ContextEngineFixtures

  def test_deepseek_cache_fields_are_disjoint
    usage = CE::Usage.from_provider('prompt_tokens' => 1000, 'completion_tokens' => 50,
                                    'prompt_cache_hit_tokens' => 800, 'prompt_cache_miss_tokens' => 200)

    assert_equal [1000, 800, 200, 50],
                 [usage.prompt_tokens, usage.cache_read_tokens, usage.uncached_input_tokens, usage.output_tokens]
    assert_in_delta 0.8, usage.cache_hit_ratio
  end

  def test_openai_cached_tokens
    usage = CE::Usage.from_provider('prompt_tokens' => 500, 'completion_tokens' => 5,
                                    'prompt_tokens_details' => { 'cached_tokens' => 128 })

    assert_equal 372, usage.uncached_input_tokens
  end

  def test_missing_usage_is_nil_and_missing_cache_fields_are_zero
    assert_nil CE::Usage.from_provider(nil)
    assert_nil CE::Usage.from_provider('prompt_tokens' => 10)
    assert_equal 0, CE::Usage.from_provider('prompt_tokens' => 10, 'completion_tokens' => 1).cache_read_tokens
  end

  def test_usage_round_trips_through_its_record
    usage = CE::Usage.from_provider('prompt_tokens' => 10, 'completion_tokens' => 1, 'prompt_cache_hit_tokens' => 7)

    assert_equal usage, CE::Usage.from_h(usage.to_h)
  end

  def calibrated
    entries = scripted_turn(3)
    messages = CE::Surface.messages(entries, header:, resolve:)
    longer = CE::Surface.messages(tool_round(entries, 'n', 'read_file', {}, 'abc'), header:, resolve:)
    [messages, longer, CE::TokenMeter.calibrate(messages:, tools: header.tools, prompt_tokens: 5000)]
  end

  def test_meter_adds_a_heuristic_for_appended_messages_to_the_reported_prefix
    messages, longer, calibration = calibrated
    appended = CE::TokenMeter.messages_heuristic(longer.drop(messages.length))

    assert_equal 5000 + appended, CE::TokenMeter.estimate(messages: longer, tools: header.tools, calibration:)
  end

  def test_meter_ignores_calibration_when_the_prefix_changed
    _, longer, calibration = calibrated
    changed = [longer.first.merge('content' => 'different')] + longer.drop(1)
    expected = CE::TokenMeter.messages_heuristic(changed) + CE::TokenMeter.heuristic(header.tools)

    assert_equal expected, CE::TokenMeter.estimate(messages: changed, tools: header.tools, calibration:)
  end

  def test_meter_ignores_calibration_when_the_tools_changed
    messages, longer, calibration = calibrated

    refute_equal 5000 + CE::TokenMeter.messages_heuristic(longer.drop(messages.length)),
                 CE::TokenMeter.estimate(messages: longer, tools: [], calibration:)
  end

  def test_policy_defaults
    policy = CE::Policy.default

    assert_equal [800, 920, 160],
                 [policy.threshold_tokens(1000), policy.backstop_tokens(1000), policy.retain_tokens(1000)]
    assert_in_delta(0.5, CE::Policy.from_h('threshold_ratio' => 0.5).threshold_ratio)
  end

  def test_policy_refuses_unknown_keys_and_inverted_ratios
    assert_raises(CE::Error) { CE::Policy.from_h('nope' => 1) }
    assert_raises(CE::Error) { CE::Policy.from_h(retain_ratio: 0.9) }
  end

  def test_trace_summary_reports_the_cache_hit_ratio_and_series_starts
    records = [{ 'series_starts' => true, 'usage' => { 'prompt_tokens' => 100, 'cache_read_tokens' => 0 } },
               { 'series_starts' => false, 'usage' => { 'prompt_tokens' => 300, 'cache_read_tokens' => 200 } },
               { 'series_starts' => false, 'usage' => nil }]

    assert_equal({ 'requests' => 3, 'with_usage' => 2, 'prompt_tokens' => 400, 'cache_read_tokens' => 200,
                   'uncached_input_tokens' => 200, 'cache_hit_ratio' => 0.5, 'series_starts' => 1,
                   'undeclared_header_changes' => 0 },
                 CE::Trace.summarize(records))
  end

  # The prefix_breaker control: a header that moves on every request must be flagged.
  def test_the_trace_verifier_flags_a_header_that_moves_without_a_trigger
    broken = Array.new(4) { |index| { 'series_starts' => true, 'series_reason' => index.zero? ? 'initial' : 'change' } }
    healthy = [{ 'series_reason' => 'initial' }, { 'series_reason' => nil }, { 'series_reason' => 'series' }]

    assert_equal 3, CE::Trace.undeclared_changes(broken).length
    assert_empty CE::Trace.undeclared_changes(healthy)
  end
end
