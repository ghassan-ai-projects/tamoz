# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative '../agenteval/topologies/pack'
require_relative 'support/topology_spec'

# Topology bar rows H1-H5: the hard pack defeats a single search, its graders are proven by controls before any paid
# run, and they read the durable record. No model is called here.
class AgentevalTopologyPackTest < Minitest::Test
  include TopologySpec

  PACK = Agenteval::TopologyPack

  def test_h2_h4_every_control_trips_exactly_its_own_gate_and_grep_fails_chain_and_survey
    assert_empty PACK.prove
  end

  def test_h4_a_blinded_grader_is_caught_by_its_control
    %i[redundant? unread_review?].each do |method|
      original = PACK::Graders.method(method)
      PACK::Graders.define_singleton_method(method) { |*| false }
      begin
        refute_empty PACK.prove(seeds: [1]), "blinding #{method} went unnoticed"
      ensure
        PACK::Graders.define_singleton_method(method, original)
      end
    end
  end

  def test_h1_a_chain_needle_that_shares_a_word_with_the_prompt_is_refused
    scenario = PACK.chain(1)
    spec = scenario.controls.fetch(:spec)
    word = PACK.words(scenario.files.fetch('a').fetch(spec.needle)).first
    hinted = scenario.with(sessions: [PACK::S.new(prompt: "#{scenario.sessions.first.prompt} Hint: #{word}.")])

    assert_empty PACK.validate([scenario])
    assert_match(/shares/, PACK.validate([hinted]).join)
  end

  def test_h3_the_big_survey_overflows_a_32k_window_twice_over
    big = PACK.survey(1, padded: true)
    small = big.with(files: { 'a' => big.files.fetch('a').transform_values { |text| text[0, 200] } })

    assert_operator big.files.fetch('a').values.sum(&:bytesize) / 4, :>, 2 * PACK::WINDOW
    assert_match(/must exceed/, PACK.validate([small]).join)
  end

  def test_h2_the_survey_key_is_executed_and_a_wrong_key_is_caught
    scenario = PACK.survey(1, padded: false)
    spec = scenario.controls.fetch(:spec)
    flipped = spec.with(answer: spec.answer.drop(1))

    assert_empty PACK.survey_key_problems(scenario)
    assert_equal 1, PACK.survey_key_problems(scenario.with(controls: { spec: flipped })).length
  end

  def record(children_runs)
    Agenteval::SubagentPack::Record.new(
      parent: { 'work_trace' => children_runs.map(&:first) }, children: children_runs.map(&:last), journal: [],
      texts: { 'hit' => 'lib/money.rb:1:def format_amount(value) = value.to_s' }
    )
  end

  def test_h4_a_review_that_saw_the_change_only_in_a_search_hit_is_not_unread
    started = { 'event' => 'subagent_started', 'role' => 'review', 'execution_id' => 'r',
                'changed' => ['lib/money.rb'] }
    searched = { 'work_execution_id' => 'r', 'work_observations' => { 'lib/export/x_ledger.rb' => { 'read' => true } },
                 'work_entries' => [{ 'kind' => 'tool_result', 'name' => 'search_text', 'text_ref' => 'hit' }] }
    blind = searched.merge('work_entries' => [])

    refute PACK::Graders.unread_review?(record([[started, searched]]))
    assert PACK::Graders.unread_review?(record([[started, blind]]))
  end

  def test_h4_two_fanout_children_given_the_same_brief_are_redundant_whatever_they_read
    run = lambda do |id, digest, path|
      started = { 'event' => 'subagent_started', 'role' => 'explore', 'execution_id' => id, 'batch' => 'b',
                  'brief_digest' => digest }
      [started, { 'work_execution_id' => id, 'work_observations' => { path => { 'read' => true } } }]
    end

    assert PACK::Graders.redundant?(record([run.call('a', 'same', 'lib/a.rb'), run.call('b', 'same', 'lib/b.rb')]))
    refute PACK::Graders.redundant?(record([run.call('a', 'one', 'lib/a.rb'), run.call('b', 'two', 'lib/b.rb')]))
  end

  def test_h5_the_record_of_a_real_fanout_and_review_names_each_child_and_its_handed_paths
    spec_row('H5') do
      parent = lambda do |root|
        [{ calls: [plan_call(paths: %w[lib], checks: [])] }, { calls: [read_call('lib/a.rb')] },
         { calls: [patch_call(root, 'lib/a.rb', 'A = 1', 'A = 2')] },
         { calls: [fanout_call([marked_brief('H5-A'), marked_brief('H5-B')])] },
         { calls: [['delegate', { 'role' => 'review', 'brief' => 'H5-R: check the change.' }]] }, { content: 'Done.' }]
      end
      children = { 'H5-A' => answer('H5-A'),
                   'H5-B' => [{ calls: [read_call('lib/export/csv.rb')] }, { content: 'H5-B csv rounds half-up.' }],
                   'H5-R' => [{ calls: [read_call('lib/a.rb')] }, { content: 'No defects found.' }] }
      topology_run(parent:, children:) do |_outcome, _model, _root, adapter|
        runs = Agenteval::SubagentPack::Record.read(adapter.path).child_runs

        assert_equal(%w[explore explore review], runs.map { |started, _| started['role'] })
        assert_equal 1, runs.first(2).map { |started, _| started['batch'] }.uniq.length
        assert_equal ['lib/a.rb'], runs.last.first['changed']
        assert_empty PACK::Graders.trial_gates(Agenteval::SubagentPack::Record.read(adapter.path), PACK.change(1))
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
