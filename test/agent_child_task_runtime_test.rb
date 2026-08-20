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
      File.write(File.join(rt.workspace, 'note.txt'), "child evidence\n")
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

  def test_enqueue_and_adopt_are_durable_and_adoption_is_exactly_once
    child = Tamoz::Agent::ChildTask.build(
      parent_thread_id: 'parent-thread', parent_request_id: 'parent-request',
      task: 'read the note', capability_profile: {
        'capabilities' => ['local:read_file'], 'authority_revision' => 'profile:1'
      }, depth: 1, concurrency: 1
    )
    parent_profile = {
      'profile_id' => 'trusted',
      'capabilities' => ['local:read_file'], 'authority_revision' => 'profile:1',
      'max_child_depth' => 1, 'max_child_concurrency' => 1
    }

    with_runtime do |rt|
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        runtime.enqueue_child_task(child, parent_profile:)
        pending = runtime.checkpoints.pending_threads

        assert_equal child.child_id, pending.fetch(0).fetch(:thread_id)

        events = []
        worker = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread_id) { runtime.session_for(thread_id) },
          emitter: ->(event) { events << event }, once: true
        )
        worker.run

        assert_equal 'completed', runtime.child_task(child.child_id).status, events.inspect

        adoption = runtime.adopt_child_task(child.child_id, parent_thread_id: 'parent-thread')

        assert_equal adoption, runtime.adopt_child_task(child.child_id, parent_thread_id: 'parent-thread')
        assert_equal 'completed', runtime.child_adoption(child.child_id).fetch('status')
      ensure
        runtime.close
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
end
