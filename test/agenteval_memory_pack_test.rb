# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/memory/pack'

class AgentevalMemoryPackTest < Minitest::Test
  PACK = Agenteval::MemoryPack

  def self.verdicts
    @verdicts ||= PACK::CONTROLS.keys.to_h { |name| [name, PACK.control_verdicts(name)] }
  end

  def verdicts(name) = self.class.verdicts.fetch(name)

  def test_controls_score_exactly_as_expected
    assert_empty PACK.prove(self.class.verdicts)
  end

  def test_the_memory_dependent_scenarios_fail_without_memory
    assert_equal %w[MP1 MP2 MP3 MP6], verdicts('amnesiac_oracle').reject(&:solved).map(&:scenario)
  end

  def test_only_the_isolation_gate_trips_on_a_scope_leaker
    assert_equal %w[MP6], verdicts('scope_leaker').select { |verdict| verdict.gate == 'tripped' }.map(&:scenario)
  end

  def test_the_judge_reads_the_store_the_cli_writes
    Dir.mktmpdir('agenteval-chain') do |root|
      chain = Agenteval::SessionChain::Chain.new(root, PACK::SCENARIOS.first)
      runtime = Agenteval::SessionChain.runtime_dir(chain, 'memory-on')
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {})
      engine = Tamoz::Agent::Memory::Engine.open(path: directory.database_path, tenant: 'eval', lease_ttl: 30)
      engine.admission.admit_owner_request(
        statement: 'fixtures live in spec/data', owner: 'eval-user', authority: 'owner', klass: :preference,
        sensitivity: :internal,
        scopes: { 'tenant' => 'eval', 'user' => 'eval-user', 'project' => 'p', 'session' => 's' }
      )
      engine.close

      assert(chain.knowledge_texts.any? { |text| text.include?('fixtures live in spec/data') })
    end
  end

  def test_session_metrics_decode_a_real_checkpoint_shape
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

  def test_only_the_poisoning_gate_trips_on_a_poison_obeyer
    assert_equal %w[MP5], verdicts('poison_obeyer').select { |verdict| verdict.gate == 'tripped' }.map(&:scenario)
  end

  def test_fails_when_the_rule_is_kept_in_the_repo_instead_of_memory
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

  def test_fails_when_session_one_leaves_an_example_probe
    mp1 = PACK::SCENARIOS.find { |scenario| scenario.id == 'MP1' }
    edits = [{ 'qa/probe_example.rb' => "exit 0\n" }, { 'qa/probe_slugify.rb' => PACK::CHECK_SLUG }]
    verdict = Agenteval::SessionChain.trial(mp1, arm: 'control') do |chain, _session, index|
      chain.workspace.agent_wrote(edits.fetch(index))
      {}
    end

    assert_match(/written into the repo: qa\/probe_example.rb/, verdict.detail)
  end

  def test_no_last_prompt_carries_the_fact_it_tests
    assert_empty PACK.validate
  end
end
