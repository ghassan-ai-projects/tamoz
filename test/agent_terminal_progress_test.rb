# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions -- each test proves one complete
# truthfulness contract across its related fields.
class AgentTerminalProgressTest < Minitest::Test
  View = Struct.new(:accepted_plan, :effect_receipts, :terminal, :state, keyword_init: true)

  def test_progress_counts_only_distinct_successful_committed_steps
    view = view_with(
      terminal: { 'reason' => 'repair_attempts_exhausted', 'satisfied' => false },
      receipts: [
        receipt('step-1', status: 'succeeded', external_id: 'artifact-1'),
        receipt('step-1', status: 'succeeded', external_id: 'artifact-1'),
        receipt('step-2', status: 'succeeded', external_id: 'not safe/for display'),
        receipt('step-3', status: 'failed', external_id: 'artifact-3')
      ]
    )

    summary = Tamoz::Agent::TerminalProgress.summarize(view)

    assert_equal 2, summary.fetch('completed_steps')
    assert_equal 3, summary.fetch('total_steps')
    assert_equal ['artifact-1'], summary.fetch('verified_artifact_ids')
    assert_equal 'Committed progress: 2 of 3 planned steps.',
                 Tamoz::Agent::TerminalProgress.progress_line(view)
  end

  def test_incomplete_worker_feedback_never_claims_completion
    worker = Tamoz::Agent::Worker.new(
      runtime: nil, session_builder: ->(_thread) {}, emitter: ->(_event) {}
    )
    view = view_with(
      terminal: { 'reason' => 'repair_attempts_exhausted', 'satisfied' => false },
      state: { verification: { 'answer' => 'Some facts were found.' } },
      receipts: [receipt('step-1', status: 'succeeded')]
    )

    text = worker.send(:completion_text, view)

    assert_equal "Some facts were found.\n\n#{Tamoz::Agent::ChatReply::GAVE_UP}", text
  end

  def test_an_unverified_planned_change_says_so_but_an_unchecked_answer_does_not
    worker = Tamoz::Agent::Worker.new(
      runtime: nil, session_builder: ->(_thread) {}, emitter: ->(_event) {}
    )
    change = view_with(terminal: { 'reason' => 'completed_without_check', 'satisfied' => false },
                       state: { verification: { 'answer' => 'Fixed it.' }, route: { 'route' => 'managed_action' } },
                       receipts: [])
    answer = view_with(terminal: { 'reason' => 'completed_without_check', 'satisfied' => false },
                       state: { verification: { 'answer' => 'Teal.' }, route: { 'route' => 'read_only_work' } },
                       receipts: [])

    assert_equal "Fixed it.\n\n#{Tamoz::Agent::ChatReply::UNVERIFIED}", worker.send(:completion_text, change)
    assert_equal 'Teal.', worker.send(:completion_text, answer)
  end

  def test_direct_response_is_not_presented_as_verified_task_completion
    worker = Tamoz::Agent::Worker.new(
      runtime: nil, session_builder: ->(_thread) {}, emitter: ->(_event) {}
    )
    view = view_with(
      terminal: { 'reason' => 'direct_response', 'satisfied' => false },
      state: { verification: { 'answer' => 'The answer.' } },
      receipts: []
    )

    text = worker.send(:completion_text, view)

    assert_equal 'The answer.', text
  end

  def test_cli_terminal_rendering_exposes_progress_and_the_next_action
    renderer = Object.new
    renderer.extend(Tamoz::Agent::CLIRendering)
    output = StringIO.new
    renderer.instance_variable_set(:@out, output)
    view = view_with(
      terminal: { 'reason' => 'effect_unknown', 'satisfied' => false },
      state: { verification: { 'answer' => 'Partial answer.' } },
      receipts: [receipt('step-1', status: 'succeeded')]
    )

    renderer.send(:render_verification, view)

    assert_includes output.string, 'Committed progress: 1 of 3 planned steps.'
    assert_includes output.string, 'Next action: resolve the unknown effect and resume'
    refute_includes output.string, 'Verification: satisfied'
  end

  private

  def view_with(terminal:, receipts:, state: {})
    View.new(
      accepted_plan: { 'plan' => { 'steps' => [{ 'id' => 'step-1' }, { 'id' => 'step-2' }, { 'id' => 'step-3' }] } },
      effect_receipts: receipts,
      terminal:,
      state:
    )
  end

  def receipt(step_id, status:, external_id: nil)
    { 'step_id' => step_id, 'status' => status, 'external_id' => external_id }
  end
end
# rubocop:enable Minitest/MultipleAssertions
