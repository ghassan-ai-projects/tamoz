# frozen_string_literal: true

require_relative "test_helper"

class SQLiteScenarioDriverTest < Minitest::Test
  REGISTRY_DIGEST =
    "sha256:4e9e83ec3b3eeeb5b6c85217709243e347aef845bcbf000fb4a6090361d00249"
  DRIVER_DIGEST =
    "sha256:25afc66329481cfa7abaff6aec9d32ebaf8b621eec1cb2f7ebf82dfe9d0bac5d"

  def test_all_fixed_scenarios_trace_one_operation_and_exact_required_union
    manifests = []

    Dir.mktmpdir("tamoz-sqlite-scenarios") do |directory|
      scenarios.each_with_index do |scenario, index|
        manifest = driver.trace(
          scenario_id: scenario.fetch("id"),
          path: File.join(directory, "#{index}.db"),
          subject:
        )
        manifests << manifest

        assert_equal(
          scenario_registry.reference(scenario.fetch("id")),
          manifest.fetch("scenario")
        )
        assert_equal(
          [scenario.fetch("operation")],
          manifest.fetch("events").map { |event| event.fetch("operation") }.uniq
        )
        assert_equal "before_begin", manifest.fetch("events").first.fetch("point")
        assert_equal "after_commit", manifest.fetch("events").last.fetch("point")
      end
    end

    verified = scenario_registry.verify_trace_union!(
      manifests,
      boundary_registry:
    )
    assert_equal 26, verified.length
    assert_deeply_frozen(verified)
  end

  def test_trace_manifests_are_reproducible_and_pin_registry_and_driver
    assert_equal REGISTRY_DIGEST, scenario_registry.digest
    assert_equal DRIVER_DIGEST, driver_class.digest
    assert_equal 1, driver_class.definition.fetch("version")
    assert_equal(
      "immediately-before-one-direct-operation",
      driver_class.definition.fetch("arming_policy")
    )
    assert_equal(
      "atomic-start-checkpoint-and-request-transition",
      driver_class.definition.fetch("running_recovery_fixture")
    )
    assert_equal(
      "static-edge-without-dynamic-goto",
      driver_class.definition.fetch("pending_outcome_routing")
    )
    assert_deeply_frozen(driver_class.definition)

    first = trace_once("request.claim-resume")
    second = trace_once("request.claim-resume")
    assert_equal first, second
    assert_includes(
      first.fetch("events").filter_map { |event| event.fetch("statement") },
      "request.claim.active_execution"
    )
  end

  def test_dynamic_write_and_consume_fixtures_are_exactly_bounded
    writes = trace_once("checkpoint.writes-new")
    labels = writes.fetch("events").filter_map { |event| event.fetch("statement") }
                   .uniq
    assert_equal(
      %w[
        checkpoint.writes.item.0
        checkpoint.writes.item.1
      ],
      labels.grep(/\Acheckpoint\.writes\.item\./)
    )

    advance = trace_once("checkpoint.commit-advance")
    labels = advance.fetch("events").filter_map { |event| event.fetch("statement") }
                    .uniq
    assert_equal(
      ["checkpoint.commit.consume.0"],
      labels.grep(/\Acheckpoint\.commit\.consume\./)
    )
  end

  def test_fixed_setups_reach_required_identity_and_idempotency_branches
    Dir.mktmpdir("tamoz-sqlite-scenario-state") do |directory|
      resume_path = File.join(directory, "resume.db")
      driver.trace(
        scenario_id: "request.claim-resume",
        path: resume_path,
        subject:
      )
      assert_equal(
        ["claimed", "execution.phase2.a"],
        raw_row(
          resume_path,
          "SELECT status, execution_id FROM tamoz_requests"
        )
      )

      request_path = File.join(directory, "request-duplicate.db")
      driver.trace(
        scenario_id: "request.enqueue-duplicate",
        path: request_path,
        subject:
      )
      assert_equal 1, raw_scalar(
        request_path,
        "SELECT COUNT(*) FROM tamoz_requests"
      )
      assert_equal 1, raw_scalar(
        request_path,
        "SELECT COUNT(*) FROM tamoz_request_transitions"
      )

      writes_path = File.join(directory, "writes-duplicate.db")
      driver.trace(
        scenario_id: "checkpoint.writes-duplicate",
        path: writes_path,
        subject:
      )
      assert_equal 1, raw_scalar(
        writes_path,
        "SELECT COUNT(*) FROM tamoz_pending_activations"
      )
      assert_equal 2, raw_scalar(
        writes_path,
        "SELECT COUNT(*) FROM tamoz_pending_writes"
      )
    end
  end

  def test_lease_fixtures_make_monotonic_contracts_deterministic_without_sleep
    Dir.mktmpdir("tamoz-sqlite-scenario-lease") do |directory|
      validate_path = File.join(directory, "validate.db")
      old_clock = nil
      validate_observer = lambda do |point, _metadata|
        if point == :before_begin || point == "before_begin"
          old_clock ||= raw_scalar(
            validate_path,
            "SELECT greatest_backend_time_ms FROM tamoz_namespaces"
          )
        end
      end
      validated = driver.run(
        scenario_id: "lease.validate",
        path: validate_path,
        observer: validate_observer
      )
      assert_equal 0, old_clock
      assert_operator raw_scalar(
        validate_path,
        "SELECT greatest_backend_time_ms FROM tamoz_namespaces"
      ), :>, old_clock
      assert_equal(
        validated.expires_at_ms,
        raw_scalar(
          validate_path,
          "SELECT lease_expires_at_ms FROM tamoz_namespaces"
        )
      )

      renew_path = File.join(directory, "renew.db")
      old_expiry = nil
      renew_observer = lambda do |point, _metadata|
        if point == :before_begin || point == "before_begin"
          old_expiry ||= raw_scalar(
            renew_path,
            "SELECT lease_expires_at_ms FROM tamoz_namespaces"
          )
        end
      end
      renewed = driver.run(
        scenario_id: "lease.renew",
        path: renew_path,
        observer: renew_observer
      )
      assert_operator renewed.expires_at_ms, :>, old_expiry
      assert_equal(
        renewed.expires_at_ms,
        raw_scalar(
          renew_path,
          "SELECT lease_expires_at_ms FROM tamoz_namespaces"
        )
      )
    end
  end

  def test_recovery_and_checkpoint_setups_reach_distinct_branches
    Dir.mktmpdir("tamoz-sqlite-scenario-branches") do |directory|
      transition_counts = {
        "claimed" => 3,
        "running" => 4,
        "redirecting" => 3
      }
      transition_counts.each do |status, transition_count|
        path = File.join(directory, "recover-#{status}.db")
        driver.trace(
          scenario_id: "request.recover-#{status}",
          path:,
          subject:
        )
        row = raw_row(
          path,
          "SELECT status, owner_fence FROM tamoz_requests"
        )
        assert_equal status, row.fetch(0)
        assert_equal 2, row.fetch(1)
        assert_equal transition_count, raw_scalar(
          path,
          "SELECT COUNT(*) FROM tamoz_request_transitions"
        )
        next unless status == "running"

        relation = raw_row(
          path,
          <<~SQL
            SELECT r.status, c.status, r.execution_id, c.execution_id
            FROM tamoz_requests r
            JOIN tamoz_checkpoints c ON c.id = r.checkpoint_id
          SQL
        )
        assert_equal %w[running running], relation.first(2)
        assert_equal relation.fetch(2), relation.fetch(3)
      end

      fork_path = File.join(directory, "fork.db")
      driver.trace(
        scenario_id: "checkpoint.commit-fork",
        path: fork_path,
        subject:
      )
      assert_equal 3, raw_scalar(
        fork_path,
        "SELECT COUNT(*) FROM tamoz_checkpoints"
      )
      assert_equal(
        "execution.phase2.b",
        raw_scalar(
          fork_path,
          <<~SQL
            SELECT c.execution_id
            FROM tamoz_namespaces n
            JOIN tamoz_checkpoints c ON c.id = n.active_checkpoint_id
          SQL
        )
      )
    end
  end

  def test_running_recovery_fixture_converges_through_the_public_runner
    Dir.mktmpdir("tamoz-sqlite-scenario-recovery") do |directory|
      path = File.join(directory, "running.db")
      driver.trace(
        scenario_id: "request.recover-running",
        path:,
        subject:
      )
      execution_id = raw_scalar(
        path,
        "SELECT execution_id FROM tamoz_requests"
      )
      expire_active_lease(path)

      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = scenario_definition.compile(checkpointer: adapter)
      recovered = app.durable_runner.recover(
        thread: "thread.phase2",
        request_id: "request.phase2",
        owner_id: "owner.phase2.convergence"
      )

      assert_equal :completed, recovered.status
      assert_equal execution_id, recovered.execution_id
      assert_equal 2, app.history(thread: "thread.phase2").length
      assert_equal 1, app.state(thread: "thread.phase2").state.fetch(:value)
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  def test_pending_write_fixture_continues_without_reexecuting_the_node
    Dir.mktmpdir("tamoz-sqlite-scenario-pending-recovery") do |directory|
      path = File.join(directory, "pending.db")
      driver.trace(
        scenario_id: "checkpoint.writes-new",
        path:,
        subject:
      )
      expire_active_lease(path)

      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = pending_recovery_definition.compile(checkpointer: adapter)
      runner = app.durable_runner
      runner.submit(
        {},
        thread: "thread.phase2",
        request_id: "request.phase2.convergence",
        operation: :continue
      )
      recovered = runner.run_next(
        thread: "thread.phase2",
        owner_id: "owner.phase2.convergence"
      )

      assert_equal :completed, recovered.status
      assert_equal 2, app.history(thread: "thread.phase2").length
      assert_equal 1, app.state(thread: "thread.phase2").state.fetch(:value)
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  def test_stable_read_and_atomic_request_checkpoint_relations_are_real
    Dir.mktmpdir("tamoz-sqlite-scenario-relations") do |directory|
      ready_path = File.join(directory, "redirect-ready.db")
      before = nil
      observer = lambda do |point, _metadata|
        if point == :before_begin || point == "before_begin"
          before ||= logical_database_rows(ready_path)
        end
      end
      result = driver.run(
        scenario_id: "request.redirect-ready",
        path: ready_path,
        observer:
      )
      assert_equal true, result
      assert_equal before, logical_database_rows(ready_path)

      turn_path = File.join(directory, "turn.db")
      driver.trace(
        scenario_id: "checkpoint.commit-turn",
        path: turn_path,
        subject:
      )
      turn_relation = raw_row(
        turn_path,
        <<~SQL
          SELECT r.status, c.status, r.execution_id, c.execution_id
          FROM tamoz_requests r
          JOIN tamoz_checkpoints c ON c.id = r.checkpoint_id
        SQL
      )
      assert_equal %w[completed completed], turn_relation.first(2)
      assert_equal turn_relation.fetch(2), turn_relation.fetch(3)
      refute_equal "execution.phase2.a", turn_relation.fetch(2)

      failed_path = File.join(directory, "failed.db")
      driver.trace(
        scenario_id: "checkpoint.commit-failed",
        path: failed_path,
        subject:
      )
      assert_equal(
        ["failed", "failed", 0],
        raw_row(
          failed_path,
          <<~SQL
            SELECT r.status, c.status, r.retryable
            FROM tamoz_requests r
            JOIN tamoz_checkpoints c ON c.id = (
              SELECT active_checkpoint_id FROM tamoz_namespaces
            )
          SQL
        )
      )
    end
  end

  def test_missing_scenario_bad_observer_and_nonfresh_paths_fail_closed
    assert_raises(Tamoz::Evals::ExecutionError) do
      driver.trace(
        scenario_id: "request.unknown",
        path: "/tmp/unused.db",
        subject:
      )
    end

    Dir.mktmpdir("tamoz-sqlite-scenario-invalid") do |directory|
      path = File.join(directory, "existing.db")
      File.write(path, "occupied")
      assert_raises(Tamoz::Evals::ExecutionError) do
        driver.trace(
          scenario_id: "lease.release",
          path:,
          subject:
        )
      end

      fresh = File.join(directory, "fresh.db")
      assert_raises(Tamoz::Evals::ExecutionError) do
        driver.run(
          scenario_id: "lease.release",
          path: fresh,
          observer: Object.new
        )
      end
      refute File.exist?(fresh)
    end
  end

  def test_permissive_or_relative_parent_and_wrong_thread_gate_fail_closed
    relative = "relative.db"
    assert_raises(Tamoz::Evals::ExecutionError) do
      driver.run(
        scenario_id: "lease.release",
        path: relative,
        observer: ->(_point, _metadata) {}
      )
    end

    Dir.mktmpdir("tamoz-sqlite-scenario-mode") do |directory|
      File.chmod(0o755, directory)
      assert_raises(Tamoz::Evals::ExecutionError) do
        driver.run(
          scenario_id: "lease.release",
          path: File.join(directory, "tamoz.db"),
          observer: ->(_point, _metadata) {}
        )
      end
    end

    gate = fault_gate_class.new
    queue = Queue.new
    Thread.new do
      begin
        gate.call(:before_begin, {}.freeze)
      rescue StandardError => error
        queue << error
      end
    end.join
    error = queue.pop
    assert_instance_of Tamoz::Evals::ExecutionError, error
    assert_match(/changed process or thread/, error.message)
  end

  def test_manifest_validation_rejects_missing_duplicate_and_branch_drift
    manifest = trace_once("request.claim-resume")
    missing = mutable_copy(manifest)
    missing.fetch("events").delete_if do |event|
      event.fetch("statement") == "request.claim.active_execution"
    end
    redigest!(missing)
    assert_raises(Tamoz::Evals::ExecutionError) do
      scenario_registry.verify_manifest!(
        missing,
        boundary_registry:
      )
    end

    manifests = scenarios.map do |scenario|
      trace_once(scenario.fetch("id"))
    end
    manifests[-1] = manifests.first
    assert_raises(Tamoz::Evals::ExecutionError) do
      scenario_registry.verify_trace_union!(
        manifests,
        boundary_registry:
      )
    end
  end

  def test_every_fixed_scenario_stops_at_its_last_sql_branch_in_a_real_child
    skip "POSIX selector evidence requires SIGSTOP" unless Signal.list.key?("STOP")

    Dir.mktmpdir("tamoz-sqlite-scenario-process") do |directory|
      scenarios.each_with_index do |scenario, index|
        trace = driver.trace(
          scenario_id: scenario.fetch("id"),
          path: File.join(directory, "trace-#{index}.db"),
          subject:
        )
        last_sql = trace.fetch("events").reverse.find do |event|
          event.fetch("point") == "after_sql"
        end
        selector = trace.fetch("selectors").find do |candidate|
          candidate.fetch("point") == last_sql.fetch("point") &&
            candidate.fetch("statement") == last_sql.fetch("statement") &&
            candidate.fetch("occurrence") == last_sql.fetch("occurrence")
        end
        refute_nil selector

        layout = selector_control.prepare!(
          root: directory,
          name: "control-#{index}",
          filesystem_anchor: directory
        )
        scenario_reference = scenario_registry.reference(scenario.fetch("id"))
        intervention = selector_control.intervention(
          layout:,
          scenario: scenario_reference,
          selector:,
          registry: boundary_registry
        )
        result = subprocess_runner.capture(
          scenario_child_command(
            layout:,
            scenario_id: scenario.fetch("id"),
            scenario_reference:,
            selector:,
            database_path: File.join(directory, "child-#{index}.db")
          ),
          timeout_ms: 3_000,
          command: "test.sqlite-scenario.#{scenario.fetch("id")}",
          intervention:
        )

        assert intervention.verify_result!(result)
        assert_equal "KILL", result.term_signal
        assert_equal "", result.stderr.text
      end
    end
  end

  private

  def scenarios
    scenario_registry.document.fetch("scenarios")
  end

  def scenario_registry
    @scenario_registry ||= registry_class.build
  end

  def driver
    @driver ||= driver_class.new(
      scenario_registry:,
      boundary_registry:
    )
  end

  def registry_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
  end

  def driver_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioDriver, false)
  end

  def fault_gate_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioFaultGate, false)
  end

  def selector_control
    Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
  end

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end

  def subject
    {
      "id" => "tamoz-sqlite",
      "version" => Tamoz::SQLite::VERSION,
      "git_revision" => "a" * 40,
      "git_tree" => "b" * 40,
      "dirty" => false
    }
  end

  def trace_once(scenario_id)
    Dir.mktmpdir("tamoz-sqlite-scenario") do |directory|
      return driver.trace(
        scenario_id:,
        path: File.join(directory, "tamoz.db"),
        subject:
      )
    end
  end

  def subprocess_runner
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment: {},
      output_limit_bytes: 4_096,
      termination_grace_ms: 200
    )
  end

  def scenario_child_command(
    layout:,
    scenario_id:,
    scenario_reference:,
    selector:,
    database_path:
  )
    load_paths = %w[tamoz-core tamoz-graph tamoz-scheduler tamoz-stream tamoz-evals tamoz-sqlite].flat_map do |name|
      ["-I", GEM_ROOTS.fetch(name).join("lib").to_s]
    end
    descriptor = layout.descriptor
    script = <<~RUBY
      require "tamoz/evals"
      require "tamoz/sqlite"
      harness = Tamoz::Evals::Harness
      control = harness.const_get(:SQLiteSelectorControl, false)
      registry = Tamoz::SQLite.const_get(:BoundaryRegistry, false)
      scenarios = harness.const_get(:SQLiteScenarioRegistry, false).build
      driver = harness.const_get(:SQLiteScenarioDriver, false).new(
        scenario_registry: scenarios,
        boundary_registry: registry
      )
      layout = control.attach!(
        directory: #{descriptor.fetch("directory").inspect},
        device: #{descriptor.fetch("device")},
        inode: #{descriptor.fetch("inode")}
      )
      stopper = control.stopper(
        layout: layout,
        scenario: #{scenario_reference.inspect},
        selector: #{selector.inspect},
        registry: registry
      )
      driver.run(
        scenario_id: #{scenario_id.inspect},
        path: #{database_path.inspect},
        observer: stopper
      )
      abort "SQLite scenario selector returned"
    RUBY
    [RbConfig.ruby, *load_paths, "-e", script]
  end

  def raw_row(path, sql)
    database = SQLite3::Database.new(path, readonly: true, strict: true)
    database.get_first_row(sql)
  ensure
    database&.close
  end

  def raw_scalar(path, sql)
    raw_row(path, sql)&.fetch(0)
  end

  def logical_database_rows(path)
    database = SQLite3::Database.new(path, readonly: true, strict: true)
    tables = database.execute(
      <<~SQL
        SELECT name
        FROM sqlite_schema
        WHERE type = 'table' AND name LIKE 'tamoz_%'
        ORDER BY name
      SQL
    ).flatten
    tables.to_h do |table|
      quoted = %("#{table.gsub('"', '""')}")
      [table, database.execute("SELECT * FROM #{quoted} ORDER BY rowid")]
    end
  ensure
    database&.close
  end

  def expire_active_lease(path)
    database = SQLite3::Database.new(path, strict: true)
    database.execute(
      "UPDATE tamoz_namespaces SET lease_expires_at_ms = 0"
    )
    assert_equal 1, database.changes
  ensure
    database&.close
  end

  def scenario_definition
    Tamoz.graph(name: "tamoz-eval-sqlite-phase2", version: "1") do
      state :value, default: 0
      state :events, reduce: :append, default: []
      node(
        :work,
        implementation_name: "tamoz.eval.sqlite.work",
        version: "1"
      ) { |_state, _context| {value: 1} }
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end
  end

  def pending_recovery_definition
    Tamoz.graph(name: "tamoz-eval-sqlite-phase2", version: "1") do
      state :value, default: 0
      state :events, reduce: :append, default: []
      node(
        :work,
        implementation_name: "tamoz.eval.sqlite.work",
        version: "1"
      ) { raise "pending task was reexecuted" }
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end
  end

  def mutable_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def redigest!(document)
    document["content_digest"] = Tamoz::Evals::CanonicalJSON.content_digest(
      document,
      domain: "eval.sqlite_trace_manifest"
    )
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash
      value.each do |key, entry|
        assert_deeply_frozen(key)
        assert_deeply_frozen(entry)
      end
    when Array
      value.each { |entry| assert_deeply_frozen(entry) }
    end
  end
end
