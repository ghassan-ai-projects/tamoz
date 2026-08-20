# frozen_string_literal: true

require_relative "test_helper"

# P6-C / P6-D2: the three-valued reconciliation of a filesystem effect and the
# refusal to repeat a check or provider call whose outcome is unknown.
class AgentSessionEffectTest < Minitest::Test
  def test_reconcilable_effect_completes_from_a_proven_after_state
    with_reconcilable_effect do |store, execution_id, key|
      record = with_writer(store, "owner.after") do |writer|
        decision = prepare(writer.effects, execution_id:)
        assert_equal :reconcile, decision.action
        assert decision.record.requires_reconciliation

        writer.effects.reconcile(
          key:,
          disposition: :completed,
          actor: "tamoz.agent.reconciler",
          evidence: {"observed" => "after"}
        )
      end

      assert_equal :return, record.action
      assert_equal :succeeded, record.record.status
      refute record.record.requires_reconciliation
      assert_nil record.attempt_token
      assert_equal :succeeded, record.record.attempts.last.status
    end
  end

  def test_reconcilable_effect_gets_exactly_one_further_attempt_from_a_proven_before_state
    with_reconcilable_effect do |store, execution_id, key|
      decision = with_writer(store, "owner.before") do |writer|
        prepare(writer.effects, execution_id:)
        writer.effects.reconcile(
          key:,
          disposition: :not_applied,
          actor: "tamoz.agent.reconciler",
          evidence: {"observed" => "before"}
        )
      end

      assert_equal :execute, decision.action
      refute_nil decision.attempt_token
      assert_equal :prepared, decision.record.status
      assert_equal 2, decision.record.current_attempt
      assert_equal :abandoned, decision.record.attempts.first.status
      refute decision.record.requires_reconciliation
    end
  end

  def test_reconcilable_effect_stops_unknown_when_neither_state_is_proven
    with_reconcilable_effect do |store, execution_id, key|
      decision = with_writer(store, "owner.unknown") do |writer|
        prepare(writer.effects, execution_id:)
        writer.effects.reconcile(
          key:,
          disposition: :unknown,
          actor: "tamoz.agent.reconciler",
          evidence: {"observed" => "third-party edit"}
        )
      end

      assert_equal :unknown, decision.action
      assert_equal :unknown, decision.record.status
      assert decision.record.requires_reconciliation
      assert_nil decision.attempt_token
    end
  end

  def test_reconcile_requires_the_reconcile_head_status
    with_reconcilable_effect do |store, execution_id, key|
      with_writer(store, "owner.wrong-status") do |writer|
        error = assert_raises(Tamoz::CheckpointConflictError) do
          writer.effects.reconcile(
            key:,
            disposition: :completed,
            actor: "actor",
            evidence: {}
          )
        end
        assert_match(/cannot be reconciled/, error.message)
        prepare(writer.effects, execution_id:)
      end
    end
  end

  def test_a_stale_fence_cannot_grant_a_further_attempt
    with_reconcilable_effect do |store, execution_id, key|
      stale = nil
      with_writer(store, "owner.stale") do |writer|
        prepare(writer.effects, execution_id:)
        stale = writer.effects
      end

      with_writer(store, "owner.current") do |_writer|
        assert_raises(Tamoz::LeaseLostError) do
          stale.reconcile(
            key:,
            disposition: :not_applied,
            actor: "actor",
            evidence: {}
          )
        end
      end
    end
  end

  def test_a_completed_reconciliation_is_recordable_after_lease_loss
    with_reconcilable_effect do |store, execution_id, key|
      stale = nil
      with_writer(store, "owner.stale.completed") do |writer|
        prepare(writer.effects, execution_id:)
        stale = writer.effects
      end

      with_writer(store, "owner.current.completed") do |_writer|
        decision = stale.reconcile(
          key:,
          disposition: :completed,
          actor: "actor",
          evidence: {}
        )
        assert_equal :return, decision.action
      end
    end
  end

  def test_reconcile_appends_a_durable_transition_for_every_disposition
    with_reconcilable_effect do |store, execution_id, key, adapter|
      with_writer(store, "owner.audit") do |writer|
        prepare(writer.effects, execution_id:)
        writer.effects.reconcile(
          key:,
          disposition: :not_applied,
          actor: "operator.audit",
          evidence: {"observed" => "before"}
        )
      end

      transitions = read_transitions(adapter, key)
      assert_includes transitions.map(&:first), "reconcile.not_applied"
      row = transitions.find { |entry| entry.first == "reconcile.not_applied" }
      assert_equal "operator.audit", row.last
    end
  end

  # EU-003: an unsafe MCP call whose external outcome is unknown (mapped to
  # Tamoz::EffectUnknownError) must be completed as a terminal :unknown journal
  # receipt at the dispatcher boundary — not left running until a later recovery
  # pass — and must never be re-sent.
  def test_an_unknown_effect_error_is_completed_as_terminal_journal_unknown
    Dir.mktmpdir("tamoz-agent-effect-unknown") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      begin
        app = base_definition.compile(checkpointer: adapter)
        request = app.durable_runner.deliver({}, thread: "thread.reconcile", request_id: "request.setup")
        store = app.checkpointer
        calls = 0
        request_body = {"tool" => "mcp:server/write"}
        perform = lambda do
          calls += 1
          raise Tamoz::EffectUnknownError, "mcp non-idempotent call failed after send"
        end

        drive = lambda do |owner, request_id|
          with_writer(store, owner) do |writer|
            context = Tamoz::Context.new(
              run_id: owner, execution_id: request.execution_id,
              request_id:, task_id: "task.mcp-unsafe", effects: writer.effects
            )
            Tamoz::Agent::EffectDispatcher.run(
              context:, operation: "tool.mcp:server/write", safety: :unsafe,
              call_index: 0, request: request_body, actor: "test.caller"
            ) { perform.call }
          end
        end

        first = drive.call("owner.unknown", "request.unknown")
        assert_equal :unknown, first.status
        assert_equal 1, calls, "the ambiguous request is sent exactly once"
        assert_equal "Tamoz::EffectUnknownError", first.error.fetch("class")
        refute first.reused

        record = with_writer(store, "owner.unknown.reread") do |writer|
          writer.effects.prepare(
            execution_id: request.execution_id, task_id: "task.mcp-unsafe",
            call_index: 0, operation: "tool.mcp:server/write", safety: :unsafe,
            request: request_body
          ).record
        end
        assert_equal :unknown, record.status
        assert_equal 1, record.current_attempt
        assert_equal :unknown, record.attempts.last.status

        second = drive.call("owner.unknown.redrive", "request.unknown2")
        assert_equal :unknown, second.status
        assert_equal 1, calls, "a re-drive of a terminal unknown effect never re-sends"
      ensure
        adapter&.close
      end
    end
  end

  # The production McpSourceBuilder mapping is the one that feeds the dispatcher:
  # an MCP ambiguous outcome becomes Tamoz::EffectUnknownError (not a repairable
  # ToolError), so the terminal-unknown completion above is reached in production.
  def test_mcp_source_builder_maps_ambiguous_outcome_to_effect_unknown
    mapped = Tamoz::Agent::McpSourceBuilder.allocate.send(
      :map_mcp_error, Tamoz::Mcp::AmbiguousOutcomeError.new("sent before transport failure")
    )
    assert_instance_of Tamoz::EffectUnknownError, mapped
    refute_kind_of Tamoz::Agent::ToolError, mapped
  end

  # --- filesystem reconciler ------------------------------------------------

  def test_filesystem_reconciler_maps_observations_to_exactly_one_disposition
    Dir.mktmpdir("tamoz-reconcile") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      before = "value = 1\n"
      after = "value = 2\n"
      intent = {
        "tool" => "apply_patch",
        "path" => "app.rb",
        "before_state" => Digest::SHA256.hexdigest(before),
        "after_digest" => Digest::SHA256.hexdigest(after)
      }
      target = File.join(root, "app.rb")

      File.write(target, after)
      assert_equal :completed, reconcile_fs(toolbox, intent).first

      File.write(target, before)
      assert_equal :not_applied, reconcile_fs(toolbox, intent).first

      File.write(target, "someone else edited this\n")
      assert_equal :unknown, reconcile_fs(toolbox, intent).first

      File.delete(target)
      assert_equal :unknown, reconcile_fs(toolbox, intent).first
    end
  end

  def test_create_file_reconciler_requires_the_exact_mode_as_well_as_the_digest
    Dir.mktmpdir("tamoz-reconcile-create") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      content = "hello\n"
      intent = {
        "tool" => "create_file",
        "path" => "greeting.txt",
        "before_state" => "absent",
        "after_digest" => Digest::SHA256.hexdigest(content),
        "after_mode" => 0o644
      }
      target = File.join(root, "greeting.txt")

      assert_equal :not_applied, reconcile_fs(toolbox, intent).first

      File.write(target, content)
      File.chmod(0o644, target)
      assert_equal :completed, reconcile_fs(toolbox, intent).first

      File.chmod(0o600, target)
      assert_equal :unknown, reconcile_fs(toolbox, intent).first
    end
  end

  # --- declared safety ------------------------------------------------------

  def test_configured_checks_are_unsafe_unless_the_operator_declares_otherwise
    Dir.mktmpdir("tamoz-check-safety") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(
        root:,
        allow_changes: true,
        checks: {"tests" => ["true"], "lint" => ["true"]},
        check_safeties: {"lint" => :read_only}
      )

      assert_equal :unsafe, toolbox.check_safety("tests")
      assert_equal :read_only, toolbox.check_safety("lint")
      assert_equal :unsafe, toolbox.check_safety("not-configured")
    end
  end

  def test_check_safety_declarations_are_validated
    Dir.mktmpdir("tamoz-check-safety-bad") do |root|
      assert_raises(ArgumentError) do
        Tamoz::Agent::Toolbox.new(
          root:,
          allow_changes: true,
          checks: {"tests" => ["true"]},
          check_safeties: {"tests" => :whatever}
        )
      end
      assert_raises(ArgumentError) do
        Tamoz::Agent::Toolbox.new(
          root:,
          allow_changes: true,
          checks: {"tests" => ["true"]},
          check_safeties: {"missing" => :read_only}
        )
      end
    end
  end

  def test_catalog_digest_changes_with_the_declared_check_safety
    Dir.mktmpdir("tamoz-catalog") do |root|
      base = Tamoz::Agent::Toolbox.new(
        root:,
        allow_changes: true,
        checks: {"tests" => ["true"]}
      )
      declared = Tamoz::Agent::Toolbox.new(
        root:,
        allow_changes: true,
        checks: {"tests" => ["true"]},
        check_safeties: {"tests" => :read_only}
      )
      read_only = Tamoz::Agent::Toolbox.new(root:)

      refute_equal base.catalog_digest, declared.catalog_digest
      refute_equal base.catalog_digest, read_only.catalog_digest
      assert_equal base.catalog_digest,
                   Tamoz::Agent::Toolbox.new(
                     root:,
                     allow_changes: true,
                     checks: {"tests" => ["true"]}
                   ).catalog_digest
    end
  end

  def test_effect_intent_preflight_writes_nothing_and_matches_the_preview
    Dir.mktmpdir("tamoz-intent") do |root|
      target = File.join(root, "app.rb")
      File.write(target, "value = 1\n")
      before = Digest::SHA256.hexdigest(File.read(target))
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "app.rb",
        "expected_sha256" => before,
        "before" => "value = 1",
        "after" => "value = 2"
      }

      intent = toolbox.effect_intent("apply_patch", arguments)
      preview = toolbox.preview("apply_patch", arguments)

      assert_equal before, intent.fetch("before_state")
      assert_equal Digest::SHA256.hexdigest("value = 2\n"), intent.fetch("after_digest")
      assert_includes preview, "+value = 2"
      assert_equal "value = 1\n", File.read(target), "preflight must not write"

      toolbox.execute("apply_patch", arguments)
      assert_equal(
        intent.fetch("after_digest"),
        Digest::SHA256.hexdigest(File.read(target))
      )
    end
  end

  private

  def reconcile_fs(toolbox, intent)
    Tamoz::Agent::EffectDispatcher.reconcile_filesystem(
      toolbox:,
      intent:,
      receipt: {"output" => "reconciled"}
    )
  end

  # Prepares a :reconcilable effect, starts it, then expires the attempt so the next
  # prepare sees exactly the ambiguous state a crash mid-effect leaves behind.
  def with_reconcilable_effect
    Dir.mktmpdir("tamoz-agent-effect") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        limits: Tamoz::SQLite::Limits.new(effect_attempt_ttl: 0.1)
      )
      app = base_definition.compile(checkpointer: adapter)
      request = app.durable_runner.deliver(
        {},
        thread: "thread.reconcile",
        request_id: "request.setup"
      )
      store = app.checkpointer
      key = nil
      token = nil
      with_writer(store, "owner.initial") do |writer|
        decision = prepare(writer.effects, execution_id: request.execution_id)
        key = decision.record.key
        token = decision.attempt_token
        writer.effects.start(key:, attempt_token: token)
      end
      expire_attempt(adapter.path, token)

      yield store, request.execution_id, key, adapter
    ensure
      adapter&.close
    end
  end

  def with_writer(store, owner)
    result = nil
    store.open_writer(
      thread_id: "thread.reconcile",
      namespace: [],
      owner_id: owner,
      ttl: store.writer_ttl
    ) { |writer| result = yield writer }
    result
  end

  def prepare(effects, execution_id:)
    effects.prepare(
      execution_id:,
      task_id: "task.patch",
      call_index: 0,
      operation: "tool.apply_patch",
      safety: :reconcilable,
      request: {"tool" => "apply_patch"}
    )
  end

  def base_definition
    Tamoz.graph(name: "agent-effect-base", version: "1") do
      state :ready, default: false
      node(:finish, implementation_name: "agent.effect.finish", version: "1") do |_state, _context|
        {ready: true}
      end
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def expire_attempt(path, token)
    database = SQLite3::Database.new(path)
    database.execute(
      "UPDATE tamoz_effect_attempts SET deadline_ms = 0 WHERE attempt_token = ?",
      [token]
    )
  ensure
    database&.close
  end

  def read_transitions(adapter, key)
    adapter.__send__(:read, operation: "test.transitions") do |tx|
      tx.rows(
        "test.transitions",
        <<~SQL,
          SELECT transition, actor FROM tamoz_effect_transitions
          WHERE effect_key = ? ORDER BY transition_index
        SQL
        [key]
      )
    end
  end
end
