# frozen_string_literal: true

require_relative 'test_helper'

class HarnessProtocolTest < Minitest::Test
  H = Tamoz::Harness

  def plan(paths: %w[lib], checks: %w[test], steps: [{ 'title' => 'Fix', 'status' => 'pending' }])
    H::PlanDocument.parse('goal' => 'Fix the bug', 'done_when' => ['tests pass'],
                          'scope' => { 'paths' => paths, 'checks' => checks }, 'steps' => steps,
                          'ruled_out' => ['patching the test — it encodes the contract'])
  end

  def test_plan_scope_is_path_prefix_based
    assert plan.in_scope?('lib/a.rb')
    assert plan.in_scope?('./lib/deep/b.rb')
    refute plan.in_scope?('library/a.rb')
  end

  def test_widening_the_scope_is_detected_and_narrowing_is_not
    assert plan(paths: %w[lib test]).widens?(plan)
    assert plan(checks: %w[test lint]).widens?(plan)
    refute plan(paths: %w[lib/deep]).widens?(plan)
  end

  def test_scope_cannot_be_escaped_with_dot_dot
    refute plan.in_scope?('lib/../Gemfile')
    refute plan.in_scope?('lib/x/../../etc/passwd')
    assert plan.in_scope?('lib/x/../y.rb')
  end

  def test_scope_paths_are_cleaned_and_patterns_refused
    assert_equal %w[lib], plan(paths: %w[./lib/ lib//. lib]).paths
    assert_raises(H::PlanError) { plan(paths: %w[lib/**]) }
  end

  def test_null_optional_lists_mean_empty
    parsed = H::PlanDocument.parse('goal' => 'g', 'done_when' => ['d'],
                                   'scope' => { 'paths' => ['lib'], 'checks' => nil },
                                   'steps' => [{ 'title' => 't', 'status' => 'pending' }], 'decisions' => nil)

    assert_equal [[], []], [parsed.checks, parsed.document.fetch('decisions')]
  end

  def test_plan_refuses_paths_outside_the_workspace_and_bad_statuses
    assert_raises(H::PlanError) { plan(paths: %w[../etc]) }
    assert_raises(H::PlanError) { plan(paths: %w[/etc]) }
    assert_raises(H::PlanError) { plan(steps: [{ 'title' => 'x', 'status' => 'maybe' }]) }
  end

  def test_plan_render_keeps_the_ruled_out_section_and_digest_is_stable
    assert_includes plan.render, "Ruled out:\n- patching the test — it encodes the contract"
    assert_equal plan.digest, plan.digest
    refute_equal plan.digest, plan(paths: %w[src]).digest
  end

  def test_tool_calls_unknown_names_bad_json_and_overflow_become_errors
    calls = [{ 'id' => '1', 'name' => 'read_file', 'arguments' => '{"path":"a"}' },
             { 'id' => '2', 'name' => 'rm_rf', 'arguments' => '{}' },
             { 'id' => '3', 'name' => 'read_file', 'arguments' => '{bad' }] +
            Array.new(8) { |index| { 'id' => "x#{index}", 'name' => 'read_file', 'arguments' => '{}' } }
    parsed = H::ToolCalls.parse(calls, allowed: %w[read_file])

    assert_equal({ 'path' => 'a' }, parsed.first.arguments)
    assert_equal [false, false], parsed[1, 2].map(&:ok?)
    assert_equal(3, parsed.count { |call| call.error&.include?('too many') })
  end

  def test_a_repeat_after_a_change_is_a_new_signature
    refute_equal H::LoopPolicy.signature('run_check', { 'name' => 'test' }, epoch: 0),
                 H::LoopPolicy.signature('run_check', { 'name' => 'test' }, epoch: 1)
  end

  def test_duplicate_json_keys_are_an_error_fed_back
    call = H::ToolCalls.parse([{ 'id' => '1', 'name' => 'read_file', 'arguments' => '{"path":"a","path":"b"}' }],
                              allowed: %w[read_file]).first

    refute_predicate call, :ok?
  end

  def test_repeat_guard_reminds_at_three_and_five_and_stops_at_eight
    policy = H::LoopPolicy.default
    signature = H::LoopPolicy.signature('read_file', { 'path' => 'a' })
    verdicts = (0..7).map { |seen| policy.repeat([signature] * seen, signature).first }

    assert_equal %i[ok ok remind ok remind ok ok stop], verdicts
    assert_includes policy.reminder('read_file', 3), 'read_file with the same arguments 3 times'
  end

  def test_budgets_name_what_ran_out
    policy = H::LoopPolicy.from_h(max_model_calls: 2)

    assert_equal 'model_call_budget', policy.exhausted(model_calls: 2, tool_calls: 0, seconds: 0)
    assert_nil policy.exhausted(model_calls: 1, tool_calls: 0, seconds: 0)
  end

  def test_an_unverified_change_is_never_reported_done
    assert_equal 'done_unverified', H::Finish.status(mutated: true, verified_after_last_mutation: false)
    assert_equal 'done', H::Finish.status(mutated: true, verified_after_last_mutation: true)
    assert_equal 'answered', H::Finish.status(mutated: false, verified_after_last_mutation: false)
  end

  def test_handoff_note_carries_reason_task_and_plan
    note = H::Handoff.note(plan:, reason: 'second compaction', task: 'Fix the bug')

    assert_includes note, 'Stopped because: second compaction'
    assert_includes note, "# Plan\nGoal: Fix the bug"
  end
end
