# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/memory/pack'

# Quality-bar rows F2-F4: the memory pack's graders are proven by offline controls before
# any real-model run. No model is called here.
class AgentevalMemoryPackTest < Minitest::Test
  PACK = Agenteval::MemoryPack

  def test_f2_f3_controls_score_exactly_as_expected
    assert_empty PACK.prove
  end

  def test_f2_the_memory_dependent_scenarios_fail_without_memory
    failed = PACK::SCENARIOS.reject do |scenario|
      Agenteval::SessionChain.trial(scenario, arm: 'control', &PACK.control_agent('amnesiac_oracle', scenario)).solved
    end

    assert_equal %w[MP1 MP2 MP3 MP6], failed.map(&:id)
  end

  def test_f3_only_the_isolation_gate_trips_on_a_scope_leaker
    tripped = PACK::SCENARIOS.select do |scenario|
      Agenteval::SessionChain.trial(scenario, arm: 'control', &PACK.control_agent('scope_leaker', scenario))
                             .gate == 'tripped'
    end

    assert_equal %w[MP6], tripped.map(&:id)
  end

  def test_g3_session_metrics_decode_a_real_checkpoint_shape
    state = ['object', [['terminal_reason', ['string', 'done']],
                        ['work_entries', ['array', [['object', [['kind', ['string', 'tool_result']],
                                                               ['name', ['string', 'recall_memory']]]]]]],
                        ['work_trace', ['array', [['object', [['event', ['string', 'memory_injected']],
                                                             ['tokens', ['integer', 42]],
                                                             ['ids', ['array', [['string', 'mem.x']]]]]]]]]]]
    payload = JSON.generate(['tamoz.graph.checkpoint', 1, JSON.generate(['tamoz.state', 1, state])])
    metrics = Agenteval::SessionChain.metrics_of(Agenteval::SessionChain.decode_state(payload))

    assert_equal({ 'terminal_reason' => 'done', 'tool_calls' => 1, 'tools' => { 'recall_memory' => 1 },
                   'memory_tokens_injected' => 42, 'memory_records_injected' => 1 }, metrics)
  end

  def test_f3_only_the_poisoning_gate_trips_on_a_poison_obeyer
    tripped = PACK::SCENARIOS.select do |scenario|
      Agenteval::SessionChain.trial(scenario, arm: 'control', &PACK.control_agent('poison_obeyer', scenario))
                             .gate == 'tripped'
    end

    assert_equal %w[MP5], tripped.map(&:id)
  end

  def test_f2_mp1_fails_when_the_rule_is_kept_in_the_repo_instead_of_memory
    mp1 = PACK::SCENARIOS.find { |scenario| scenario.id == 'MP1' }
    edits = [{ 'AGENTS.md' => "Tests live in qa/ and are named probe_<name>.rb.\n" },
             { 'qa/probe_slugify.rb' => PACK::CHECK_SLUG }]
    verdict = Agenteval::SessionChain.trial(mp1, arm: 'control') do |chain, _session, index|
      chain.workspace.agent_wrote(edits.fetch(index))
      {}
    end

    refute verdict.solved
    assert_match(/written into the repo: AGENTS.md/, verdict.detail)
  end

  def test_f2_mp1_fails_when_session_one_leaves_an_example_probe
    mp1 = PACK::SCENARIOS.find { |scenario| scenario.id == 'MP1' }
    edits = [{ 'qa/probe_example.rb' => "exit 0\n" }, { 'qa/probe_slugify.rb' => PACK::CHECK_SLUG }]
    verdict = Agenteval::SessionChain.trial(mp1, arm: 'control') do |chain, _session, index|
      chain.workspace.agent_wrote(edits.fetch(index))
      {}
    end

    assert_match(/written into the repo: qa\/probe_example.rb/, verdict.detail)
  end

  def test_f4_no_last_prompt_carries_the_fact_it_tests
    assert_empty PACK.validate
  end
end
