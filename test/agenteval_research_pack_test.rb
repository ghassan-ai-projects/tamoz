# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/research/pack'

# The research pack's offline controls (docs/deep-research-2026-09-30/EVAL.md §3): every grader separates a planted
# good report from a planted bad one before any real-model number is read.
class AgentevalResearchPackTest < Minitest::Test
  Pack = Agenteval::Research::Pack

  def test_every_grader_control_holds
    failed = Pack.controls.reject(&:last).map(&:first)

    assert_empty failed
  end

  def test_the_question_set_is_pre_registered_in_its_design_shape
    dev = Pack.questions('dev')
    held_out = Pack.questions('held_out')

    assert_equal [6, 8], [dev.length, held_out.length]
    assert_equal %w[comparison contested current factual survey], held_out.map { |q| q.fetch('class') }.uniq.sort
    Pack.questions.each do |question|
      question.fetch('facts').each { |fact| fact.fetch('any').each { |pattern| Regexp.new(pattern) } }
      assert question['after'] || !question.fetch('facts').empty?, "#{question['id']} grades nothing"
    end
  end

  def test_the_arms_differ_only_in_children_per_wave
    fanout, single = Pack::ARMS.values_at('fanout', 'single')

    assert_equal fanout.fetch('ceilings'), single.fetch('ceilings').except('children_per_wave')
    assert_equal 1, single.dig('ceilings', 'children_per_wave')
    Pack::ARMS.each_value { |override| Tamoz::Research.budgets(override:) }
  end

  def test_the_judge_reads_a_nested_answer_whole_not_inner_object_first
    text = "Sure!\n{\"comprehensiveness\": \"A\", \"detail\": {\"depth\": 2}, \"insight\": \"B\"}\nThanks"
    extracted = JSON.parse(Agenteval::Research::Judge.object_in(text))

    assert_equal({ 'comprehensiveness' => 'A', 'detail' => { 'depth' => 2 }, 'insight' => 'B' }, extracted)
    assert_nil Agenteval::Research::Judge.object_in('no object here')
  end
end
