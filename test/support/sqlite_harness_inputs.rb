# frozen_string_literal: true

module SQLiteHarnessInputs
  module_function

  def registry
    registry_class = Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
    @registry ||= registry_class.new(
      scenarios,
      maximum_scenarios: 32,
      families: %w[lease request checkpoint],
      state_classes: %w[old new stable]
    )
  end

  def driver_definition
    @driver_definition ||= Tamoz::Evals::DeepFreeze.call(
      {
        "id" => "tamoz.sqlite.scenario_driver",
        "version" => 1,
        "scenario_limit" => 32,
        "path_policy" => "fresh-absolute-private-parent",
        "bootstrap_policy" => "fault-gate-disarmed",
        "arming_policy" => "immediately-before-one-direct-operation",
        "background_threads" => "prohibited",
        "running_recovery_shape" =>
          "atomic-start-checkpoint-and-request-transition",
        "pending_outcome_routing" =>
          "static-edge-without-dynamic-goto",
        "graph" => graph,
        "limits" => limits
      }
    )
  end

  def graph
    @graph ||= Tamoz::Evals::DeepFreeze.call(
      {
        "name" => "tamoz-eval-sqlite-phase2",
        "version" => "1",
        "channels" => %w[value events],
        "nodes" => ["work"]
      }
    )
  end

  def limits
    @limits ||= Tamoz::Evals::DeepFreeze.call(
      {
        "requests" => 1,
        "lease_acquisitions" => 2,
        "setup_checkpoints" => 2,
        "subject_checkpoints" => 1,
        "tasks" => 1,
        "pending_writes" => 2,
        "consumed_tasks" => 1
      }
    )
  end

  def runtime_identifiers
    {
      "thread_id" => "thread.phase2",
      "owner_a" => "owner.phase2.a",
      "owner_b" => "owner.phase2.b",
      "owner_id" => "owner.phase2.convergence",
      "request_id" => "request.phase2",
      "execution_a" => "execution.phase2.a",
      "execution_b" => "execution.phase2.b"
    }
  end

  def probe_definition
    @probe_definition ||= Tamoz::Evals::DeepFreeze.call(
      {
        "id" => "tamoz.sqlite.convergence_probe",
        "version" => 1,
        "scenario_probes" => probes,
        "classification_precondition" =>
          "independent-oracle-complete-state-only",
        "process_policy" => "caller-must-spawn-fresh-process",
        "lease_policy" => "classified-copy-with-expiry-elision",
        "ledger_policy" =>
          "separate-synchronous-full-unique-logical-invocation",
        "graph" => graph,
        "output_policy" =>
          "canonical-bounded-facts-without-path-owner-or-raw-identity"
      }
    )
  end

  def probe_inputs
    {
      graph_factory: method(:graph_factory),
      probes: probes,
      request_states: request_states,
      checkpoint_states: checkpoint_states,
      request_checkpoint_states: request_checkpoint_states,
      recovery_history_counts: recovery_history_counts,
      identifiers: runtime_identifiers.merge("ledger_invocation" => "work.phase2")
    }
  end

  def driver
    driver_class = Tamoz::Evals::Harness.const_get(:SQLiteScenarioDriver, false)
    @driver ||= driver_class.new(
      scenario_registry: registry,
      boundary_registry: Tamoz::SQLite.const_get(:BoundaryRegistry, false),
      definition: driver_definition,
      runtime_inputs: runtime_inputs
    )
  end

  def subprocess_runner
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment: {},
      output_limit_bytes: 4_096,
      termination_grace_ms: 200
    )
  end

  def child_command(layout:, scenario_id:, scenario_reference:, selector:, database_path:)
    descriptor = layout.descriptor
    script = <<~RUBY
      require 'tamoz/evals/runner'
      require 'tamoz/sqlite'
      require 'support/sqlite_harness_inputs'
      control = Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
      registry = Tamoz::SQLite.const_get(:BoundaryRegistry, false)
      layout = control.attach!(directory: #{descriptor.fetch('directory').inspect},
        device: #{descriptor.fetch('device')}, inode: #{descriptor.fetch('inode')})
      stopper = control.stopper(layout: layout, scenario: #{scenario_reference.inspect},
        selector: #{selector.inspect}, registry: registry)
      SQLiteHarnessInputs.driver.run(
        scenario_id: #{scenario_id.inspect}, path: #{database_path.inspect},
        observer: stopper
      )
      abort 'SQLite scenario selector returned'
    RUBY
    [RbConfig.ruby, *SUBPROCESS_LIB_ARGS, '-e', script]
  end

  def runtime_inputs
    {
      "graph" => graph,
      "graph_factory" => method(:graph_factory),
      "identifiers" => runtime_identifiers,
      "preparers" => preparers,
      "failure_payload" => failure_payload
    }
  end

  def graph_factory(name:, version:)
    Tamoz.graph(name:, version:) do
      state :value, default: 0
      state :events, reduce: :append, default: []
      node(:work, implementation_name: "tamoz.eval.sqlite.work", version: "1") do |_state, _context|
        yield if block_given?
        {value: 1}
      end
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end
  end

  def failure_payload
    [
      {
        "graph" => graph.fetch("name"),
        "node" => "work",
        "task_id" => "task.phase2",
        "attempt_id" => "attempt.phase2",
        "error_class" => "ScenarioFailure",
        "safe_message" => "fixed failure"
      }
    ]
  end

  def probe
    probe_class = Tamoz::Evals::Harness.const_get(:SQLiteConvergenceProbe, false)
    @probe ||= probe_class.new(
      scenario_registry: registry,
      definition: probe_definition,
      inputs: probe_inputs
    )
  end

  def scenario(id, family:, operation:, coverage:, state_classes: %w[old new])
    {
      "id" => id,
      "version" => 1,
      "family" => family,
      "operation" => operation,
      "setup" => id,
      "action" => operation,
      "state_classes" => state_classes,
      "contract" => id,
      "convergence" => id,
      "coverage" => coverage
    }
  end

  def scenarios
    @scenarios ||= begin
      lease_acquire = %w[
        lease.acquire.time lease.acquire.thread lease.acquire.thread_state
        lease.acquire.namespace lease.acquire.row lease.acquire.update
      ]
      lease_validate = %w[
        lease.validate.time lease.validate.thread lease.validate.row
        lease.validate.clock
      ]
      lease_renew = %w[
        lease.renew.time lease.renew.thread lease.renew.row lease.renew.update
      ]
      lease_release = %w[
        lease.release.time lease.release.row lease.release.update
      ]
      enqueue_new = %w[
        request.enqueue.time request.enqueue.thread request.enqueue.tombstone
        request.enqueue.namespace request.enqueue.existing request.enqueue.sequence
        request.enqueue.insert request.transition.index request.transition.insert
        request.enqueue.advance request.enqueue.result
      ]
      enqueue_duplicate = %w[
        request.enqueue.time request.enqueue.thread request.enqueue.tombstone
        request.enqueue.namespace request.enqueue.existing
      ]
      claim_base = %w[
        request.claim.time request.claim.lease.thread request.claim.lease.row
        request.claim.candidates
      ]
      claim_tail = %w[
        request.claim.update request.transition.index request.transition.insert
        request.claim.result
      ]
      recover = %w[
        request.recover.time request.recover.lease.thread request.recover.lease.row
        request.recover.row request.recover.earlier request.recover.update
        request.transition.index request.transition.insert request.recover.result
      ]
      transition = %w[
        request.transition.time request.transition.lease.thread
        request.transition.lease.row request.commit.row request.commit.update
        request.transition.index request.transition.insert request.transition.result
      ]
      writes = %w[
        checkpoint.writes.time checkpoint.writes.lease.thread
        checkpoint.writes.lease.row checkpoint.writes.base checkpoint.writes.existing
      ]
      commit = %w[
        checkpoint.commit.time checkpoint.commit.lease.thread
        checkpoint.commit.lease.row checkpoint.commit.head
      ]
      request_commit = %w[
        request.commit.row request.commit.update request.transition.index
        request.transition.insert
      ]
      list = [
        scenario("lease.acquire-new", family: "lease", operation: "lease.acquire", coverage: lease_acquire),
        scenario("lease.acquire-takeover", family: "lease", operation: "lease.acquire", coverage: lease_acquire),
        scenario("lease.validate", family: "lease", operation: "lease.validate", coverage: lease_validate),
        scenario("lease.renew", family: "lease", operation: "lease.renew", coverage: lease_renew),
        scenario("lease.release", family: "lease", operation: "lease.release", coverage: lease_release),
        scenario("request.enqueue-new", family: "request", operation: "request.enqueue", coverage: enqueue_new),
        scenario("request.enqueue-duplicate", family: "request", operation: "request.enqueue", state_classes: ["stable"], coverage: enqueue_duplicate),
        scenario("request.claim-turn", family: "request", operation: "request.claim", coverage: claim_base + claim_tail),
        scenario("request.claim-resume", family: "request", operation: "request.claim", coverage: claim_base + ["request.claim.active_execution"] + claim_tail),
        scenario("request.claim-redirect", family: "request", operation: "request.claim", coverage: claim_base + %w[request.claim.redirect_target request.claim.cancellation_generation] + claim_tail),
        scenario("request.claim-stale", family: "request", operation: "request.claim", coverage: claim_base + %w[request.claim.latest_checkpoint request.terminal_fail request.transition.index request.transition.insert request.claim.result]),
        scenario("request.recover-claimed", family: "request", operation: "request.recover", coverage: recover),
        scenario("request.recover-running", family: "request", operation: "request.recover", coverage: recover),
        scenario("request.recover-redirecting", family: "request", operation: "request.recover", coverage: recover),
        scenario("request.recover-stale", family: "request", operation: "request.recover", coverage: %w[request.recover.time request.recover.lease.thread request.recover.lease.row request.recover.row request.recover.earlier request.recover.latest_checkpoint request.terminal_fail request.transition.index request.transition.insert request.recover.result]),
        scenario("request.mark-running", family: "request", operation: "request.transition", coverage: transition),
        scenario("request.mark-redirect-running", family: "request", operation: "request.transition", coverage: transition),
        scenario("request.redirect-ready", family: "request", operation: "request.redirect_ready", state_classes: ["stable"], coverage: %w[request.redirect_ready.time request.redirect_ready.lease.thread request.redirect_ready.lease.row request.redirect_ready.effects]),
        scenario("checkpoint.writes-new", family: "checkpoint", operation: "checkpoint.append_writes", coverage: writes + %w[checkpoint.writes.activation checkpoint.writes.item.{index}]),
        scenario("checkpoint.writes-duplicate", family: "checkpoint", operation: "checkpoint.append_writes", state_classes: ["stable"], coverage: writes + ["checkpoint.writes.verify"]),
        scenario("checkpoint.commit-start", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.insert checkpoint.commit.advance]),
        scenario("checkpoint.commit-advance", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.base checkpoint.commit.insert checkpoint.commit.consume.{index} checkpoint.commit.advance]),
        scenario("checkpoint.commit-turn", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.base checkpoint.commit.insert] + request_commit + ["checkpoint.commit.advance"]),
        scenario("checkpoint.commit-fork", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.base checkpoint.commit.insert checkpoint.commit.advance]),
        scenario("checkpoint.commit-paused", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.base checkpoint.commit.insert checkpoint.commit.advance]),
        scenario("checkpoint.commit-failed", family: "checkpoint", operation: "checkpoint.commit", coverage: commit + %w[checkpoint.commit.base checkpoint.commit.insert] + request_commit + ["checkpoint.commit.advance"])
      ]
      Tamoz::Evals::DeepFreeze.call(list)
    end
  end

  def probes
    @probes ||= scenarios.to_h do |entry|
      family = entry.fetch("family")
      operation = entry.fetch("operation")
      probe = case [family, operation]
              when ["lease", "lease.acquire"], ["lease", "lease.validate"], ["lease", "lease.renew"], ["lease", "lease.release"] then "lease-fencing"
              when ["request", "request.enqueue"], ["request", "request.claim"], ["request", "request.transition"] then "inbox-reopen"
              when ["request", "request.recover"] then entry.fetch("id").end_with?("stale") ? "stale-request-fail" : "request-recovery"
              when ["request", "request.redirect_ready"] then "checkpoint-reopen"
              when ["checkpoint", "checkpoint.append_writes"] then "pending-write-replay"
              when ["checkpoint", "checkpoint.commit"] then entry.fetch("id").match?(/turn|failed/) ? "request-checkpoint-reopen" : "checkpoint-reopen"
              end
      probe = "duplicate-delivery" if entry.fetch("id") == "request.enqueue-duplicate"
      probe = "stale-request-fail" if entry.fetch("id") == "request.claim-stale"
      [entry.fetch("id"), probe]
    end.freeze
  end

  def request_states
    {
      "request.enqueue-new" => {"old" => nil, "new" => "queued"},
      "request.claim-turn" => {"old" => "queued", "new" => "claimed"},
      "request.claim-resume" => {"old" => "queued", "new" => "claimed"},
      "request.claim-redirect" => {"old" => "queued", "new" => "redirecting"},
      "request.claim-stale" => {"old" => "queued", "new" => "failed"},
      "request.mark-running" => {"old" => "claimed", "new" => "running"},
      "request.mark-redirect-running" => {"old" => "redirecting", "new" => "running"},
      "request.recover-stale" => {"old" => "claimed", "new" => "failed"}
    }
  end

  def checkpoint_states
    {
      "request.redirect-ready" => {"stable" => [1, "running"]},
      "checkpoint.commit-start" => {"old" => [0, nil], "new" => [1, "running"]},
      "checkpoint.commit-advance" => {"old" => [1, "running"], "new" => [2, "completed"]},
      "checkpoint.commit-fork" => {"old" => [2, "completed"], "new" => [3, "completed"]},
      "checkpoint.commit-paused" => {"old" => [1, "running"], "new" => [2, "paused"]}
    }
  end

  def request_checkpoint_states
    {
      "checkpoint.commit-turn" => {"old" => [1, "running", "claimed"], "new" => [2, "completed", "completed"]},
      "checkpoint.commit-failed" => {"old" => [1, "running", "claimed"], "new" => [2, "failed", "failed"]}
    }
  end

  def recovery_history_counts
    {
      "request.recover-claimed" => 2,
      "request.recover-running" => 2,
      "request.recover-redirecting" => 3
    }
  end

  def preparers
    @preparers ||= scenarios.to_h do |entry|
      [entry.fetch("id"), "prepare_#{entry.fetch("id").tr(".", "_").tr("-", "_")}" ]
    end
  end
end
