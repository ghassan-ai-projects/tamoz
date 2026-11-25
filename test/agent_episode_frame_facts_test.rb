# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tamoz/agent'

# A frame never drops a snapshot fact silently: every fact reaches the model, in order, or the frame is refused.
class AgentEpisodeFrameFactsTest < Minitest::Test
  Agent = Tamoz::Agent
  CATALOG = [{ 'code' => 'unknown', 'description' => 'unknown described' }].freeze

  def test_the_limit_is_256_and_a_snapshot_at_the_limit_passes_through_complete_and_in_order
    names = fact_names(256)
    frame = build(names)

    assert_equal 256, Agent::EpisodeFrameBuilder::MAX_FACTS
    assert_equal(names, frame.facts.map { |entry| entry.fetch('name') })
    assert_equal(names.map { |name| "fact:#{name}" }, shown_ids(frame))
  end

  def test_the_phase_counts_as_a_fact_and_comes_first
    frame = build(fact_names(255), 'phase' => 'running')

    assert_equal Agent::EpisodeFrameBuilder::PHASE_FACT, frame.facts.first.fetch('name')
    assert_equal 256, frame.facts.length
  end

  def test_more_than_the_limit_is_refused_not_truncated
    error = assert_raises(Agent::EpisodeFrameError) { build(fact_names(257)) }

    assert_equal 'episode_frame/too_many_facts: 257 facts, limit 256', error.message
    assert_raises(Agent::EpisodeFrameError) { build(fact_names(256), 'phase' => 'running') }
  end

  def test_the_former_limit_of_64_no_longer_cuts_a_snapshot
    names = fact_names(70)

    assert_equal(names, build(names).facts.map { |entry| entry.fetch('name') })
  end

  def test_the_error_message_is_disclosable_to_the_operator
    assert_kind_of Tamoz::DisclosableMessage, Agent::EpisodeFrameError.new('episode_frame/too_many_facts: 257')
  end

  private

  def shown_ids(frame) = JSON.parse(frame.user).fetch('situation').map { |entry| entry.fetch('id') }

  def fact_names(count) = Array.new(count) { |index| format('fact_%03d', index) }

  def build(names, extras = {})
    snapshot = { 'facts' => names.to_h { |name| [name, 1] } }.merge(extras)
    Agent::EpisodeFrameBuilder.new(catalog: Agent::DiagnosisCatalog.from_list(CATALOG), objective: '')
                              .build(snapshot:, prompt: 'Diagnose.')
  end
end
