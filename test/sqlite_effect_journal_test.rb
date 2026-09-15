# frozen_string_literal: true

require_relative "test_helper"

class SQLiteEffectJournalTest < Minitest::Test
  def test_prepare_start_complete_is_idempotent_and_succeeded_is_immutable
    with_effect_store do |_adapter, app, store, execution_id|
      completed = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.effect",
        ttl: store.writer_ttl
      ) do |writer|
        decision = prepare_effect(
          writer.effects,
          execution_id:,
          safety: :idempotent
        )
        assert_equal :execute, decision.action
        refute_nil decision.attempt_token
        running = writer.effects.start(
          key: decision.record.key,
          attempt_token: decision.attempt_token
        )
        assert_equal :running, running.status

        completed = writer.effects.complete(
          key: decision.record.key,
          attempt_token: decision.attempt_token,
          status: :succeeded,
          result: {"receipt" => "ok"},
          external_id: "external.1"
        )
        assert_equal :succeeded, completed.status
        duplicate = writer.effects.complete(
          key: decision.record.key,
          attempt_token: decision.attempt_token,
          status: :succeeded,
          result: {"receipt" => "ok"},
          external_id: "external.1"
        )
        assert_equal completed, duplicate
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.replay",
        ttl: store.writer_ttl
      ) do |writer|
        replay = prepare_effect(
          writer.effects,
          execution_id:,
          safety: :idempotent
        )
        assert_equal :return, replay.action
        assert_nil replay.attempt_token
        assert_equal(
          {"receipt" => "ok"},
          replay.record.attempts.last.result
        )
        assert_raises(Tamoz::CheckpointConflictError) do
          writer.effects.complete(
            key: replay.record.key,
            attempt_token: completed.attempts.last.attempt_token,
            status: :succeeded,
            result: {"receipt" => "different"},
            external_id: "external.1"
          )
        end
      end
      assert_equal :completed, app.state(thread: "thread.effects").status
    end
  end

  def test_effect_census_preserves_request_association_separately_from_effect_identity
    with_effect_store do |_adapter, _app, store, execution_id|
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.association",
        ttl: store.writer_ttl
      ) do |writer|
        first = prepare_effect(
          writer.effects, execution_id:, task_id: "task.first", request_id: "request.first",
          safety: :idempotent
        )
        second = prepare_effect(
          writer.effects, execution_id:, task_id: "task.second", request_id: "request.second",
          safety: :idempotent
        )

        census = store.effect_census
        assert_equal "request.first", census.find { |row| row[:effect_key] == first.record.key }[:request_id]
        assert_equal "request.second", census.find { |row| row[:effect_key] == second.record.key }[:request_id]
      end
    end
  end

  # Canonicality is a byte property. SQLite hands BLOB columns back as
  # ASCII-8BIT while the state codec dumps UTF-8, so an encoding-sensitive
  # `==` forged a CheckpointCorruptionError for any receipt that was not
  # ASCII-only — every real model reply containing an em dash, a curly quote,
  # or an accent crashed the durable session on replay.
  def test_non_ascii_effect_receipt_replays_without_forging_corruption
    receipt = {"reply" => "résumé — “quoted” ✅"}
    with_effect_store do |_adapter, _app, store, execution_id|
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.effect",
        ttl: store.writer_ttl
      ) do |writer|
        decision = prepare_effect(
          writer.effects,
          execution_id:,
          safety: :idempotent
        )
        writer.effects.start(
          key: decision.record.key,
          attempt_token: decision.attempt_token
        )
        completed = writer.effects.complete(
          key: decision.record.key,
          attempt_token: decision.attempt_token,
          status: :succeeded,
          result: receipt,
          external_id: "external.utf8"
        )
        assert_equal receipt, completed.attempts.last.result
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.replay",
        ttl: store.writer_ttl
      ) do |writer|
        replay = prepare_effect(
          writer.effects,
          execution_id:,
          safety: :idempotent
        )
        assert_equal :return, replay.action
        assert_equal receipt, replay.record.attempts.last.result
      end
    end
  end

  def test_effect_start_requires_current_graph_fence_but_late_receipt_does_not
    with_effect_store do |_adapter, _app, store, execution_id|
      old_effects = nil
      decision = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.old",
        ttl: store.writer_ttl
      ) do |writer|
        old_effects = writer.effects
        decision = prepare_effect(
          old_effects,
          execution_id:,
          safety: :unsafe
        )
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.new",
        ttl: store.writer_ttl
      ) do |_writer|
        assert_raises(Tamoz::LeaseLostError) do
          old_effects.start(
            key: decision.record.key,
            attempt_token: decision.attempt_token
          )
        end
      end

      started_effects = nil
      started = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.start",
        ttl: store.writer_ttl
      ) do |writer|
        started_effects = writer.effects
        started = prepare_effect(
          started_effects,
          execution_id:,
          task_id: "task.late",
          safety: :unsafe
        )
        started_effects.start(
          key: started.record.key,
          attempt_token: started.attempt_token
        )
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.takeover",
        ttl: store.writer_ttl
      ) do |_writer|
        receipt = started_effects.complete(
          key: started.record.key,
          attempt_token: started.attempt_token,
          status: :succeeded,
          result: {"late" => true}
        )
        assert_equal :succeeded, receipt.status
        assert_equal({"late" => true}, receipt.attempts.last.result)
      end
    end
  end

  def test_expired_unsafe_running_attempt_becomes_unknown_and_can_record_late_truth
    with_effect_store do |adapter, _app, store, execution_id|
      old_effects = nil
      decision = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.unsafe",
        ttl: store.writer_ttl
      ) do |writer|
        old_effects = writer.effects
        decision = prepare_effect(
          old_effects,
          execution_id:,
          task_id: "task.unsafe",
          safety: :unsafe
        )
        old_effects.start(
          key: decision.record.key,
          attempt_token: decision.attempt_token
        )
      end
      expire_attempt(adapter.path, decision.attempt_token)

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.unsafe.recover",
        ttl: store.writer_ttl
      ) do |writer|
        recovery = prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.unsafe",
          safety: :unsafe
        )
        assert_equal :unknown, recovery.action
        assert_equal :unknown, recovery.record.status
        assert_nil recovery.attempt_token
      end

      late = old_effects.complete(
        key: decision.record.key,
        attempt_token: decision.attempt_token,
        status: :succeeded,
        result: {"truth" => "target succeeded"}
      )
      assert_equal :succeeded, late.status
      assert_equal(
        {"truth" => "target succeeded"},
        late.attempts.last.result
      )
    end
  end

  def test_running_unsafe_attempt_from_an_old_fence_becomes_unknown_without_waiting
    with_effect_store do |_adapter, _app, store, execution_id|
      old_effects = nil
      decision = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.unsafe.old-fence",
        ttl: store.writer_ttl
      ) do |writer|
        old_effects = writer.effects
        decision = prepare_effect(
          old_effects,
          execution_id:,
          task_id: "task.unsafe.old-fence",
          safety: :unsafe
        )
        old_effects.start(key: decision.record.key, attempt_token: decision.attempt_token)
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.unsafe.takeover",
        ttl: store.writer_ttl
      ) do |writer|
        recovery = prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.unsafe.old-fence",
          safety: :unsafe
        )
        assert_equal :unknown, recovery.action
        assert_equal :unknown, recovery.record.status
        assert_nil recovery.attempt_token
      end
    end
  end

  def test_late_old_success_is_retained_without_overwriting_new_succeeded_head
    with_effect_store do |adapter, _app, store, execution_id|
      old_effects = nil
      first = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.idempotent.old",
        ttl: store.writer_ttl
      ) do |writer|
        old_effects = writer.effects
        first = prepare_effect(
          old_effects,
          execution_id:,
          task_id: "task.idempotent",
          safety: :idempotent
        )
        old_effects.start(
          key: first.record.key,
          attempt_token: first.attempt_token
        )
      end
      expire_attempt(adapter.path, first.attempt_token)

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.idempotent.new",
        ttl: store.writer_ttl
      ) do |writer|
        second = prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.idempotent",
          safety: :idempotent
        )
        assert_equal :execute, second.action
        writer.effects.start(
          key: second.record.key,
          attempt_token: second.attempt_token
        )
        writer.effects.complete(
          key: second.record.key,
          attempt_token: second.attempt_token,
          status: :succeeded,
          result: {"attempt" => 2}
        )
      end

      after_late = old_effects.complete(
        key: first.record.key,
        attempt_token: first.attempt_token,
        status: :succeeded,
        result: {"attempt" => 1}
      )
      assert_equal :succeeded, after_late.status
      assert after_late.requires_reconciliation
      assert_equal 2, after_late.attempts.length
      assert_equal(
        [{"attempt" => 1}, {"attempt" => 2}],
        after_late.attempts.map(&:result)
      )
    end
  end

  def test_human_resolution_is_audited_and_succeeded_head_is_not_overwritten
    with_effect_store do |adapter, _app, store, execution_id|
      journal = nil
      decision = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.resolve.start",
        ttl: store.writer_ttl
      ) do |writer|
        journal = writer.effects
        decision = prepare_effect(
          journal,
          execution_id:,
          task_id: "task.resolve",
          safety: :unsafe
        )
        journal.start(
          key: decision.record.key,
          attempt_token: decision.attempt_token
        )
      end
      expire_attempt(adapter.path, decision.attempt_token)

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.resolve.human",
        ttl: store.writer_ttl
      ) do |writer|
        unknown = prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.resolve",
          safety: :unsafe
        )
        assert_equal :unknown, unknown.action
        resolved = writer.effects.resolve(
          key: decision.record.key,
          status: :succeeded,
          actor: "operator.1",
          evidence: {"ticket" => "INC-1"}
        )
        assert_equal :succeeded, resolved.status
      end

      late = journal.complete(
        key: decision.record.key,
        attempt_token: decision.attempt_token,
        status: :failed,
        error: {"message" => "late target failure"}
      )
      assert_equal :succeeded, late.status
      assert late.requires_reconciliation
      assert_equal :failed, late.attempts.last.status
    end
  end

  def test_human_resolution_refuses_a_foreign_writer_row_scope
    with_effect_store do |_adapter, _app, store, execution_id|
      decision = nil
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.a.start",
        ttl: store.writer_ttl
      ) do |writer|
        decision = prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.scope",
          safety: :unsafe
        )
        writer.effects.start(
          key: decision.record.key,
          attempt_token: decision.attempt_token
        )
      end
      expire_attempt(store.adapter.path, decision.attempt_token)
      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.a.unknown",
        ttl: store.writer_ttl
      ) do |writer|
        assert_equal :unknown, prepare_effect(
          writer.effects,
          execution_id:,
          task_id: "task.scope",
          safety: :unsafe
        ).action
      end

      store.open_writer(
        thread_id: "thread.b",
        namespace: [],
        owner_id: "owner.b.human",
        ttl: store.writer_ttl
      ) do |writer|
        assert_raises(Tamoz::CheckpointConflictError) do
          writer.effects.resolve(
            key: decision.record.key,
            status: :succeeded,
            actor: "operator.b",
            evidence: {"ticket" => "INC-2"}
          )
        end
      end

      store.open_writer(
        thread_id: "thread.effects",
        namespace: [],
        owner_id: "owner.a.human",
        ttl: store.writer_ttl
      ) do |writer|
        resolved = writer.effects.resolve(
          key: decision.record.key,
          status: :succeeded,
          actor: "operator.a",
          evidence: {"ticket" => "INC-2"}
        )
        assert_equal :succeeded, resolved.status
      end
    end
  end

  def test_durable_runner_rejects_an_unbound_effect_journal
    Dir.mktmpdir("tamoz-effect-context") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      app = base_definition.compile(checkpointer: adapter)
      context = Tamoz::Context.new(
        run_id: "run.unbound",
        execution_id: "execution.unbound",
        request_id: "request.unbound",
        effects: Object.new
      )
      assert_raises(Tamoz::ConfigurationError) do
        app.durable_runner.deliver(
          {},
          thread: "thread.unbound",
          request_id: "request.unbound",
          context:
        )
      end
      adapter.close
    end
  end

  private

  def with_effect_store
    Dir.mktmpdir("tamoz-effects") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      app = base_definition.compile(checkpointer: adapter)
      request = app.durable_runner.deliver(
        {},
        thread: "thread.effects",
        request_id: "request.setup"
      )
      yield adapter, app, app.checkpointer, request.execution_id
      adapter.close
    end
  end

  def base_definition
    Tamoz.graph(name: "effect-base", version: "1") do
      state :ready, default: false
      node(
        :finish,
        implementation_name: "effect.finish",
        version: "1"
      ) { |_state, _context| {ready: true} }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def prepare_effect(
    effects,
    execution_id:,
    task_id: "task.effect",
    request_id: nil,
    safety:
  )
    effects.prepare(
      execution_id:,
      task_id:,
      call_index: 0,
      operation: "device.write",
      safety:,
      request: {"value" => 1},
      request_id:
    )
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
end
