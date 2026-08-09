# frozen_string_literal: true

require_relative 'test_helper'

class GraphResumeAnswersTest < Minitest::Test
  Interrupt = Data.define(:task_id, :call_index)
  Checkpoint = Data.define(:status, :interrupts, :resume_values)
  Request = Data.define(:payload)

  def setup
    klass = Tamoz::Graph.const_get(:ResumeAnswers, false)
    @answers = klass.new(codec: Tamoz::StateCodec.new)
  end

  def test_merge_normalizes_answers_and_freezes_the_result
    checkpoint = paused_checkpoint

    merged = @answers.merge(checkpoint, { 'ask' => { 0 => { 'answer' => 'yes' } } })

    assert_equal({ 'ask' => { 0 => { 'answer' => 'yes' } } }, merged)
    assert_predicate merged, :frozen?
    assert_predicate merged.fetch('ask'), :frozen?
  end

  def test_stale_reason_rejects_unknown_and_already_merged_answers
    checkpoint = paused_checkpoint(resume_values: { 'ask' => { 0 => 'old' } })

    assert_equal(
      'resume answer does not match an outstanding task/call index',
      @answers.stale_reason(checkpoint, Request.new({ 'other' => { 0 => 'new' } }))
    )
    assert_equal(
      'resume answer already exists for call index 0',
      @answers.stale_reason(checkpoint, Request.new({ 'ask' => { 0 => 'new' } }))
    )
  end

  private

  def paused_checkpoint(resume_values: {})
    Checkpoint.new(
      :paused,
      [Interrupt.new('ask', 0)],
      resume_values
    )
  end
end
