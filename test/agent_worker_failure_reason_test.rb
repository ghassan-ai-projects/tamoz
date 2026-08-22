# frozen_string_literal: true

require_relative 'test_helper'

# The worker's settled-failure reason derivation: an operator reading a
# request.failed event must see WHY the turn failed — the bounded tool-failure
# signature, the terminal reason, or the first three STRUCTURAL review issues —
# never the opaque "failed" the session view used to hide behind. Reviewer
# prose (semantic/protocol feedback) stays hidden; model output is never
# echoed, exactly like the raised PlanRejectedError disclosure.
class AgentWorkerFailureReasonTest < Minitest::Test
  def worker
    @worker ||= Tamoz::Agent::Worker.new(runtime: nil, session_builder: nil, emitter: nil)
  end

  def view_with(state)
    Tamoz::Agent::SessionView.new(
      thread_id: 'tg.t', checkpoint_id: 'c', sequence: 1, execution_id: 'e', request_id: 'r',
      status: :failed, phase: 'repair', accepted_plan: nil, approvals: [],
      effect_receipts: [], blocked: nil, terminal: nil, provider_ambiguity: nil,
      interrupts: [], state:
    )
  end

  def test_a_repair_plan_rejection_reports_the_terminal_reason_and_structural_issues
    state = {
      terminal_reason: 'repair_plan_rejected',
      plan_reviews: [
        { 'review_id' => 'r1', 'layer' => 'semantic', 'decision' => 'revise',
          'issues' => ['reviewer prose that must stay hidden'] },
        { 'review_id' => 'r2', 'layer' => 'structural', 'decision' => 'revise',
          'issues' => ['plan must list at least one tool step', 'unexpected tool: rm'] }
      ],
      observations: []
    }

    reason = worker.send(:settled_failure_reason, view_with(state))

    assert_equal 'repair_plan_rejected: plan must list at least one tool step; unexpected tool: rm', reason
  end

  def test_a_tool_failure_reports_the_bounded_failure_signature
    state = {
      terminal_reason: 'completed_without_check',
      observations: [
        { 'step_id' => 's1', 'tool' => 'apply_patch', 'output' => 'tool failed',
          'failure' => { 'kind' => 'tool_error', 'tool' => 'apply_patch',
                         'error_class' => 'Tamoz::Agent::ToolError',
                         'reason' => 'patch rejected', 'failure_signature' => 'x' } }
      ]
    }

    reason = worker.send(:settled_failure_reason, view_with(state))

    assert_equal 'Tamoz::Agent::ToolError:patch rejected', reason
  end

  def test_a_terminal_reason_without_issues_is_reported_alone
    reason = worker.send(:settled_failure_reason, view_with(terminal_reason: 'repeated_action', observations: []))

    assert_equal 'repeated_action', reason
  end

  def test_a_rejection_whose_last_review_is_not_structural_reports_only_the_terminal_reason
    state = {
      terminal_reason: 'repair_plan_rejected',
      plan_reviews: [{ 'review_id' => 'r1', 'layer' => 'semantic', 'decision' => 'revise',
                       'issues' => ['hidden prose'] }],
      observations: []
    }

    reason = worker.send(:settled_failure_reason, view_with(state))

    assert_equal 'repair_plan_rejected', reason
  end

  def test_without_any_failure_signal_the_reason_stays_opaque_but_bounded
    reason = worker.send(:settled_failure_reason, view_with({ observations: [] }))

    assert_equal 'failed', reason
  end
end
