# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class AgentChildTaskRuntimeTest < Minitest::Test
  include AutonomyCase

  # One scenario proves create idempotence, CAS transition, reopen, and completion.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
  def test_child_task_is_durable_and_cas_transition_is_idempotence_boundary
    child = Tamoz::Agent::ChildTask.build(
      parent_thread_id: 'parent-thread', parent_request_id: 'parent-request',
      task: 'read the note', capability_profile: {
        'capabilities' => ['local:read_file'], 'authority_revision' => 'profile:1'
      }, depth: 1, concurrency: 1
    )

    with_runtime do |rt|
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      parent_profile = {
        'capabilities' => ['local:read_file'], 'authority_revision' => 'profile:1',
        'max_child_depth' => 1, 'max_child_concurrency' => 1
      }
      runtime.create_child_task(child, parent_profile:)

      assert_equal child.child_id, runtime.create_child_task(child, parent_profile:).child_id
      running = runtime.transition_child_task(child.child_id, &:start)

      assert_equal 'running', running.status
      runtime.close

      reopened = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        assert_equal 'running', reopened.child_task(child.child_id).status
        completed = reopened.transition_child_task(child.child_id) { |record| record.complete(receipt: 'done') }

        assert_equal 'completed', completed.status
      ensure
        reopened.close
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
end
