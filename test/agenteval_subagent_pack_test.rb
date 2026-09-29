# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative '../agenteval/subagents/pack'
require_relative 'support/subagent_fixtures'

# Quality-bar rows F1-F4: the subagent pack's graders are proven by offline controls before any real-model run, and
# they read the durable session record. No model is called here.
class AgentevalSubagentPackTest < Minitest::Test
  include SubagentFixtures

  PACK = Agenteval::SubagentPack

  def test_f1_f2_controls_trip_exactly_their_own_gate
    assert_empty PACK.prove
  end

  # A control suite that cannot fail proves nothing: blind each grader in turn and the suite must object.
  def test_f1_each_blinded_grader_is_caught_by_its_control
    { 'step_repetition' => [:repetition, ->(*) {}],
      'inconclusive' => [:inconclusive?, ->(*) { false }] }.each do |gate, (method, stub)|
      original = PACK::Graders.method(method)
      PACK::Graders.define_singleton_method(method, &stub)
      begin
        refute_empty PACK.prove.grep(/#{gate}/), "blinding #{method} went unnoticed"
      ensure
        PACK::Graders.define_singleton_method(method, original)
      end
    end
  end

  def test_f1_a_grader_that_ignores_child_namespaces_is_caught
    original = PACK::Graders::WRITES
    PACK::Graders.send(:remove_const, :WRITES)
    PACK::Graders.const_set(:WRITES, [].freeze)

    refute_empty PACK.prove.grep(/writer_child/)
  ensure
    PACK::Graders.send(:remove_const, :WRITES)
    PACK::Graders.const_set(:WRITES, original)
  end

  def test_f3_the_record_of_a_real_session_carries_what_the_graders_read
    delegating do |_outcome, model, _root, adapter|
      record = PACK::Record.read(adapter.path)
      scenario = PACK.scenarios([1]).first
      leaked = scenario.controls.fetch(:spec).canary

      assert_equal 1, record.delegations
      assert_equal %w[lib/billing/total.rb lib/export/csv.rb], record.child_reads.sort
      assert_equal(model.child_requests.length,
                   record.journal.count do |namespace, operation|
                     namespace.include?('subgraph') && operation.end_with?('work_step')
                   end)
      assert_empty PACK::Graders.trial_gates(record, scenario)
      refute(record.children.any? do |child|
        child['work_entries'].any? do |entry|
          record.text(entry).include?(leaked)
        end
      end)
      assert(record.children.first['work_entries'].any? { |entry| record.text(entry).include?('rounds half-even') })
    end
  end

  def test_f4_the_validator_refuses_a_prompt_that_names_its_needle
    scenario = PACK.scenarios([1]).first
    needle = scenario.controls.fetch(:spec).needle
    named = scenario.with(sessions: [PACK::S.new(prompt: "#{scenario.sessions.first.prompt} Look at #{needle}.")])

    assert_empty PACK.validate([scenario])
    assert_equal ["#{scenario.id} names its needle #{needle}"], PACK.validate([named])
  end

  def test_scenarios_are_seeded_and_the_needle_sits_among_two_hundred_distractors
    first, second = [1, 2].map { |seed| PACK.scenarios([seed]) }

    assert_equal(%w[SA1 SA2 SA3 SA4 SA5], first.map { |scenario| scenario.notes['family'] })
    refute_equal(first.map { |scenario| scenario.sessions.first.prompt }, second.map do |scenario|
      scenario.sessions.first.prompt
    end)
    assert_operator first.first.files.fetch('a').keys.count { |path| path.start_with?('lib/noise/') }, :>=, 200
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
