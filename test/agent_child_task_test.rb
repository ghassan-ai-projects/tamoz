# frozen_string_literal: true

require_relative 'test_helper'

class AgentChildTaskTest < Minitest::Test
  def build
    Tamoz::Agent::ChildTask.build(
      parent_thread_id: 'thread-1', parent_request_id: 'request-1',
      task: 'inspect the repository', capability_profile: {
        'capabilities' => ['local:read_file'], 'authority_revision' => 'rev-1'
      }, depth: 1, concurrency: 2
    )
  end

  def parent_profile
    {
      'capabilities' => ['local:read_file', 'local:read_dir'],
      'authority_revision' => 'rev-1',
      'max_child_depth' => 2,
      'max_child_concurrency' => 2
    }
  end

  def test_identity_is_deterministic_and_profile_is_frozen
    first = build
    second = build

    assert_equal first.child_id, second.child_id
    assert_raises(FrozenError) { first.capability_profile['authority_revision'] = 'rev-2' }
    assert_equal 'pending', first.status
  end

  def test_completion_is_terminal_and_digest_bound
    completed = build.start.complete(receipt: 'child result')

    assert_predicate completed, :adoptable?
    assert_match(/\Asha256:[0-9a-f]{64}\z/, completed.completion_digest)
    assert_raises(ArgumentError) { completed.start }
  end

  def test_unknown_result_is_not_treated_as_success
    unknown = build.start.unknown(receipt: 'remote outcome uncertain')

    assert_equal 'unknown', unknown.status
    refute_equal 'completed', unknown.status
    assert_predicate unknown, :adoptable?
  end

  def test_invalid_profile_and_budget_are_rejected
    assert_raises(ArgumentError) do
      build.class.build(parent_thread_id: 't', parent_request_id: 'r', task: 'x', capability_profile: {}, depth: 0,
                        concurrency: 0)
    end
    assert_raises(ArgumentError) do
      build.class.build(parent_thread_id: 't', parent_request_id: 'r', task: 'x',
                        capability_profile: { 'capabilities' => ['a'] }, depth: 9, concurrency: 1)
    end
  end

  def test_canonical_identity_and_parent_authority_are_verified
    child = build
    child.assert_narrowed_to!(parent_profile)
    assert_raises(Tamoz::Agent::ToolPolicyError) do
      child.assert_narrowed_to!(parent_profile.merge('capabilities' => ['local:read_dir']))
    end
    assert_raises(ArgumentError) do
      Tamoz::Agent::ChildTask.from_h(child.to_h.merge('child_id' => "child:sha256:#{'0' * 64}"))
    end
  end
end
