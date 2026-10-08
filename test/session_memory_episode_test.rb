# frozen_string_literal: true

require_relative 'test_helper'

class SessionMemoryEpisodeTest < Minitest::Test
  Configuration = Struct.new(:memory, :memory_access)

  class AccessDouble
    attr_reader :episodes

    def initialize = @episodes = []
    def record_experience(**episode) = @episodes << episode
  end

  def record(reason, satisfied: false)
    access = AccessDouble.new
    state = { terminal_reason: reason, task: 'Hello', session: { 'session_id' => 'tg.thread' } }
    Tamoz::Agent::SessionMemory.new(configuration: Configuration.new(Object.new, access))
                               .record_episode_memory(state, { 'satisfied' => satisfied, 'evidence' => [] })
    access.episodes.map { |episode| episode.fetch(:statement) }
  end

  def test_a_chat_answer_on_any_route_is_an_episode
    assert_equal ['Task: Hello | Outcome: answered'], record('answered')
    assert_equal ['Task: Hello | Outcome: direct_response'], record('direct_response')
  end

  def test_an_unverified_completion_and_a_stop_are_not
    assert_empty record('done')
    assert_empty record('handed_off')
    assert_empty record('work_failed')
  end
end
