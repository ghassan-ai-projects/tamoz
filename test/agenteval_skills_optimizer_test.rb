# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/skills/optimizer'

class AgentevalSkillsOptimizerTest < Minitest::Test
  OPT = Agenteval::SkillsPack::Optimizer
  CURRENT = File.read(File.join(Agenteval::SkillsPack::SKILL_DIR, 'SKILL.md'), encoding: Encoding::UTF_8)
  SHORTER = CURRENT.sub(/## Rules that are not negotiable.*\z/m, "## Rules that are not negotiable\n\n- No quote, no finding.\n")

  def row(id, solved:, tokens: 100) = { 'scenario' => id, 'solved' => solved, 'gates' => [], 'matched' => solved ? 1 : 0,
                                        'planted' => 1, 'clean_misjudged' => 0, 'prompt_tokens' => tokens }

  # Scores a skill directory by whether its SKILL.md is the shorter rewrite; `heldout_helps` decides held-out.
  def evaluator(heldout_helps:, seen:)
    lambda do |dir, ids|
      seen << ids
      better = File.read(File.join(dir, 'SKILL.md'), encoding: Encoding::UTF_8) == SHORTER
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
      staged = File.read(File.join(result.best, 'SKILL.md'), encoding: Encoding::UTF_8)

      assert_equal SHORTER, staged
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

  def test_a_losing_draft_is_not_promotable_and_a_refused_trial_stops_the_run
    run_optimizer(SHORTER, heldout_helps: false) do |result, _, _|
      refute File.exist?("#{result.best}.candidate.json"), 'only an accepted rewrite is staged'
    end
    refused = ->(_dir, ids) { ids.map { |id| row(id, solved: false).merge('provider_failure' => 'model_out_of_credit') } }
    Dir.mktmpdir('opt') do |staging|
      assert_raises(Agenteval::SkillsPack::ProviderUnavailable) do
        OPT.new(propose: ->(_) { SHORTER }, evaluate: refused, staging:, variants: 1).call
      end
    end
  end
end

# The optimizer runs as `agenteval skills optimize`, in a process the test helper did not prepare.
class AgentevalSkillsOptimizerLoadTest < Minitest::Test
  def test_the_optimizer_loads_what_it_uses_in_a_fresh_process
    script = 'require_relative "agenteval/skills/optimizer"; print Tamoz::Skills.respond_to?(:lint) && Tamoz::Skills::Error.name'
    out, err, status = Open3.capture3(RbConfig.ruby, '-S', 'bundle', 'exec', 'ruby', '-e', script, chdir: ROOT.to_s)

    assert status.success?, err
    assert_equal 'Tamoz::Skills::Error', out
  end
end
