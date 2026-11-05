# frozen_string_literal: true

require_relative 'sqlite_harness_states'

module SQLiteHarnessDefinitions
  module_function

  def driver_definition
    @driver_definition ||= Tamoz::Evals::DeepFreeze.call(
      {
        'id' => 'tamoz.sqlite.scenario_driver',
        'version' => 1,
        'scenario_limit' => 32,
        'path_policy' => 'fresh-absolute-private-parent',
        'bootstrap_policy' => 'fault-gate-disarmed',
        'arming_policy' => 'immediately-before-one-direct-operation',
        'background_threads' => 'prohibited',
        'running_recovery_shape' =>
          'atomic-start-checkpoint-and-request-transition',
        'pending_outcome_routing' =>
          'static-edge-without-dynamic-goto',
        'graph' => graph,
        'limits' => limits
      }
    )
  end

  def graph
    @graph ||= Tamoz::Evals::DeepFreeze.call(
      {
        'name' => 'tamoz-eval-sqlite-phase2',
        'version' => '1',
        'channels' => %w[value events],
        'nodes' => ['work']
      }
    )
  end

  def limits
    @limits ||= Tamoz::Evals::DeepFreeze.call(
      {
        'requests' => 1,
        'lease_acquisitions' => 2,
        'setup_checkpoints' => 2,
        'subject_checkpoints' => 1,
        'tasks' => 1,
        'pending_writes' => 2,
        'consumed_tasks' => 1
      }
    )
  end

  def runtime_identifiers
    {
      'thread_id' => 'thread.phase2',
      'owner_a' => 'owner.phase2.a',
      'owner_b' => 'owner.phase2.b',
      'owner_id' => 'owner.phase2.convergence',
      'request_id' => 'request.phase2',
      'execution_a' => 'execution.phase2.a',
      'execution_b' => 'execution.phase2.b'
    }
  end

  def probe_definition
    @probe_definition ||= Tamoz::Evals::DeepFreeze.call(
      {
        'id' => 'tamoz.sqlite.convergence_probe',
        'version' => 1,
        'scenario_probes' => SQLiteHarnessStates.probes,
        'classification_precondition' =>
          'independent-oracle-complete-state-only',
        'process_policy' => 'caller-must-spawn-fresh-process',
        'lease_policy' => 'classified-copy-with-expiry-elision',
        'ledger_policy' =>
          'separate-synchronous-full-unique-logical-invocation',
        'graph' => graph,
        'output_policy' =>
          'canonical-bounded-facts-without-path-owner-or-raw-identity'
      }
    )
  end

  def failure_payload
    [
      {
        'graph' => graph.fetch('name'),
        'node' => 'work',
        'task_id' => 'task.phase2',
        'attempt_id' => 'attempt.phase2',
        'error_class' => 'ScenarioFailure',
        'safe_message' => 'fixed failure'
      }
    ]
  end
end
