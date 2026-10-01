# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/skills/optimizer'

# PLAN phase 10: the optimizer rewrites only SKILL.md, never shows held-out scenarios to the proposer, and keeps a
# rewrite only when it beats the current skill on them. Scripted proposer and evaluator: no model is called.
class AgentevalSkillsOptimizerTest < Minitest::Test
  OPT = Agenteval::SkillsPack::Optimizer
  CURRENT = File.read(File.join(Agenteval::SkillsPack::SKILL_DIR, 'SKILL.md'))
  SHORTER = CURRENT.sub(/## Rules that are not negotiable.*\z/m, "## Rules that are not negotiable\n\n- No quote, no finding.\n")

  def row(id, solved:, tokens: 100) = { 'scenario' => id, 'solved' => solved, 'gates' => [], 'matched' => solved ? 1 : 0,
                                        'planted' => 1, 'clean_misjudged' => 0, 'prompt_tokens' => tokens }

  # Scores a skill directory by whether its SKILL.md is the shorter rewrite; `heldout_helps` decides held-out.
  def evaluator(heldout_helps:, seen:)
    lambda do |dir, ids|
      seen << ids
      better = File.read(File.join(dir, 'SKILL.md')) == SHORTER
      ids.map do |id|
        held = OPT::HELDOUT.include?(id)
        row(id, solved: held ? (better ? heldout_helps : !heldout_helps) || !better : true, tokens: better ? 50 : 100)
      end
    end
  end

  def run_optimizer(proposal, heldout_helps: true)
    prompts = []
    seen = []
    Dir.mktmpdir('opt') do |staging|
      result = OPT.new(propose: ->(prompt) { prompts << prompt; proposal }, staging:,
                       evaluate: evaluator(heldout_helps:, seen:), variants: 1).call
      yield result, prompts, seen
    end
  end

  def test_a_rewrite_that_wins_on_held_out_is_staged_as_a_candidate
    run_optimizer(SHORTER) do |result, _, _|
      assert result.accepted, result.reason
      assert_equal 'tamoz.skill-optimizer', result.candidate.fetch('created_by')
      assert_equal SHORTER, File.read(File.join(result.best, 'SKILL.md'))
      assert File.exist?("#{result.best}.candidate.json")
    end
  end

  def test_a_rewrite_that_only_fits_training_is_rejected
    run_optimizer(SHORTER, heldout_helps: false) do |result, _, _|
      refute result.accepted
      assert_match(/held-out/, result.reason)
    end
  end

  def test_a_rewrite_below_the_authoring_bar_is_dropped
    run_optimizer(CURRENT.sub(/description: [^\n]*/, 'description: Audits.')) do |result, _, _|
      refute result.accepted
      assert_match(/authoring bar/, result.reason)
    end
  end

  def test_the_proposer_never_sees_a_held_out_scenario
    run_optimizer(SHORTER) do |_, prompts, seen|
      OPT::HELDOUT.each { |id| refute(prompts.any? { |prompt| prompt.include?("\"#{id}\"") }, id) }
      assert_equal OPT::TRAIN, seen.first
    end
  end

  def test_scoring_prefers_solved_then_safety_then_cost
    cheap = [row('A1', solved: true, tokens: 10)]
    costly = [row('A1', solved: true, tokens: 90)]
    failing = [row('A1', solved: false, tokens: 1)]

    assert_predicate (OPT.score(cheap) <=> OPT.score(costly)), :positive?
    assert_predicate (OPT.score(costly) <=> OPT.score(failing)), :positive?
  end
end
