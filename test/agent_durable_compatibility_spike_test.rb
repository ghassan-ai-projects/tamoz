# frozen_string_literal: true

require_relative 'test_helper'

class AgentDurableCompatibilitySpikeTest < Minitest::Test
  def test_v1_graph_record_and_node_versions_are_explicitly_pinned
    assert_equal '1', Tamoz::Agent::Session::GRAPH_VERSION
    assert_equal '1', Tamoz::Agent::SessionNodes::GRAPH_VERSION
    assert_equal 1, Tamoz::Agent::SessionRecords::RECORD_VERSION
  end

  def test_v1_session_record_round_trip_preserves_graph_identity
    record = Tamoz::Agent::SessionRecords.build(
      'session',
      session_id: 'compatibility-spike',
      task: 'read the note',
      task_digest: 'a' * 64,
      root: '/tmp',
      graph_version: Tamoz::Agent::Session::GRAPH_VERSION,
      behavior_version: 'tamoz.agent.session/1',
      tool_catalog_digest: "sha256:#{'b' * 64}",
      created_at_ms: 0
    )

    loaded = Tamoz::Agent::SessionRecords.load!(record)

    assert_equal '1', loaded.fetch('graph_version')
    assert_equal 1, loaded.fetch('record_version')
  end

  def test_future_graph_identity_round_trips_without_implicit_migration
    record = Tamoz::Agent::SessionRecords.build(
      'session',
      session_id: 'compatibility-spike',
      task: 'read the note',
      task_digest: 'a' * 64,
      root: '/tmp',
      graph_version: '2',
      behavior_version: 'tamoz.agent.session/1',
      tool_catalog_digest: "sha256:#{'b' * 64}",
      created_at_ms: 0
    )

    loaded = Tamoz::Agent::SessionRecords.load!(record)

    assert_equal '1', Tamoz::Agent::Session::GRAPH_VERSION
    assert_equal '2', loaded.fetch('graph_version')
  end

  def test_runtime_rejects_a_future_graph_before_resume
    session = Tamoz::Agent::Session.allocate

    error = assert_raises(Tamoz::CheckpointVersionError) do
      session.send(
        :enforce_graph_binding!,
        'compatibility-spike',
        session: { 'graph_version' => '2' }
      )
    end

    assert_match(/graph version "2".*supports "1"/, error.message)
  end
end
