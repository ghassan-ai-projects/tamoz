# frozen_string_literal: true

require_relative "test_helper"

# DR-4 acceptance (F1-F6): a stale durable request — enqueued for a thread state that
# no longer matches at claim/recover time — fails as a TERMINAL request value inside
# the claim (or recover) transaction, never as an exception out of run_next, never as
# a silent re-claim, never a wedged queue. Covers the claim-time validator (C1/C3),
# the StaleRequestError class boundary (C2), the checkpointer-owned single-transaction
# terminal-fail (D2/C5), the recover-path validation (C4), the FIFO unblock, the
# atomicity at the new seams (F3/F5), and the CLI typed-reason rendering (D3).
class SQLiteStaleRequestTest < Minitest::Test
  # F1 shape 1 (compiled.rb:938 path): a resume whose answers no longer match the
  # current interrupts terminal-fails at claim; no exception, thread untouched,
  # never observably claimed, subsequent drain is empty.
  def test_stale_resume_against_paused_different_generation_terminal_fails_at_claim
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.d6-shape1"
      runner.deliver({}, thread:, request_id: "request.start")
      tid = task_id_for(app, thread)

      runner.submit(
        {tid => {0 => "a"}},
        thread:,
        request_id: "request.stale-resume",
        operation: :resume
      )
      # Owner B advances the thread directly so the queued resume stays queued
      # (the D-6 two-owner shape): answer index 0, re-pausing at [(tid,1)].
      advance_resume(app, store, thread, {tid => {0 => "b1"}})
      latest_before = app.state(thread:)
      assert_equal 1, latest_before.interrupts.first.call_index

      failed = runner.run_next(thread:, owner_id: "owner.a")
      refute_nil failed
      assert_equal :failed, failed.status
      assert failed.terminal?
      assert_nil failed.response
      assert_nil failed.retryable
      refute_nil failed.execution_id, "claim-time identity must be bound"
      refute_equal latest_before.execution_id, failed.execution_id,
                   "the stale request must not be bound to the advanced thread"
      assert_equal "resume answer does not match an outstanding task/call index",
                   failed.terminal_error.fetch("reason")
      assert_equal "failed", failed.terminal_error.fetch("graph_status")
      assert_equal(
        {"kind" => "claim_validation", "operation" => "resume"},
        failed.terminal_error.fetch("evidence")
      )

      # The thread's real state is untouched and still claimable.
      assert_equal latest_before, app.state(thread:)
      assert_equal :paused, app.state(thread:).status
      assert_nil runner.run_next(thread:, owner_id: "owner.a2")
      # Never observably claimed: history has enqueue -> failed only.
      stale = runner.history(thread:).find do |record|
        record.request_id == "request.stale-resume"
      end
      assert_equal %i[queued failed], transition_statuses(store, thread, stale.request_id)
    end
  end

  # F1 shape 2 (compiled.rb:527 path): a stale resume against a completed checkpoint
  # terminal-fails at claim. (A RUNNING latest checkpoint with a queued resume behind
  # it is unreachable through the FIFO claim — the running request ahead of it is
  # returned by run_next first and must resolve before the resume is selected; the
  # predicate pins the running-target precondition directly in
  # test_shared_predicate_matches_the_precondition_sites.)
  def test_stale_resume_against_completed_checkpoint_terminal_fails_at_claim
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.d6-shape2"
      runner.deliver({}, thread:, request_id: "request.start")
      tid = task_id_for(app, thread)
      runner.submit(
        {tid => {0 => "a"}},
        thread:,
        request_id: "request.stale-resume",
        operation: :resume
      )
      advance_to_completed(app, store, thread)

      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      assert_equal "latest checkpoint is not paused",
                   failed.terminal_error.fetch("reason")
      assert_equal :completed, app.state(thread:).status
    end
  end

  # F2 (:retry latent defect, compiled.rb:567 path).
  def test_stale_retry_after_the_target_recovered_terminal_fails_at_claim
    with_runner(flaky_definition) do |store, app, runner|
      thread = "thread.retry-stale"
      first = runner.deliver({}, thread:, request_id: "request.first")
      assert_equal :failed, first.status
      runner.submit({}, thread:, request_id: "request.stale-retry", operation: :retry)

      # Owner B retries directly (bypassing the queue) and completes the thread.
      advance_retry(app, store, thread)
      assert_equal :completed, app.state(thread:).status

      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      assert_equal "latest checkpoint is not failed",
                   failed.terminal_error.fetch("reason")
      assert_equal %i[queued failed],
                   transition_statuses(store, thread, "request.stale-retry")
      # The retried run's checkpoint is untouched.
      assert_equal :completed, app.state(thread:).status
    end
  end

  # F6 P2: stale :turn / :continue / :fork all terminal-fail at claim.
  def test_stale_turn_does_not_fork_the_live_execution_chain
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.stale-turn"
      runner.deliver({}, thread:, request_id: "request.start")
      history_before = app.history(thread:, limit: 100).length
      execution_before = app.state(thread:).execution_id

      runner.submit(
        {"task" => "follow up"},
        thread:,
        request_id: "request.turn",
        operation: :turn,
        delivery: :queue
      )
      failed = runner.run_next(thread:, owner_id: "owner.a")

      assert_equal :failed, failed.status
      assert_equal "latest checkpoint is not terminal",
                   failed.terminal_error.fetch("reason")
      assert_equal history_before, app.history(thread:, limit: 100).length,
                   "a stale turn must never append or fork a checkpoint"
      assert_equal execution_before, app.state(thread:).execution_id
      # The active thread's own work remains claimable.
      assert_nil runner.run_next(thread:, owner_id: "owner.a2")
    end
  end

  def test_stale_continue_against_a_paused_thread_terminal_fails_at_claim
    with_runner(multi_interrupt_definition) do |_store, _app, runner|
      thread = "thread.stale-continue"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit({}, thread:, request_id: "request.continue", operation: :continue)

      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      assert_equal "latest checkpoint has no runnable frontier",
                   failed.terminal_error.fetch("reason")
    end
  end

  def test_stale_fork_against_an_active_thread_terminal_fails_but_genuine_fork_conflicts_propagate
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.stale-fork"
      runner.deliver({}, thread:, request_id: "request.start")

      # Setup A (status-precondition): a fork while the thread is active is stale.
      runner.submit({}, thread:, request_id: "request.fork-stale", operation: :fork)
      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      assert_equal "latest checkpoint is not terminal",
                   failed.terminal_error.fetch("reason")
    end

    with_runner(request_definition) do |store, app, runner|
      thread = "thread.fork-genuine"
      runner.deliver({"input" => "one"}, thread:, request_id: "request.first")
      runner.submit(
        {"checkpoint_id" => "does-not-exist"},
        thread:,
        request_id: "request.fork-missing",
        operation: :fork
      )
      # Setup B (compiled.rb:821): the source-missing conflict is a GENUINE conflict
      # and must propagate unchanged through run_next.
      error = assert_raises(Tamoz::CheckpointConflictError) do
        runner.run_next(thread:, owner_id: "owner.a")
      end
      refute_instance_of Tamoz::StaleRequestError, error
      assert_match(/fork source checkpoint does not exist/, error.message)
    end
  end

  # DR4-08: :redirect is never claim-time validated; its wait condition (745) stays a
  # propagating CheckpointConflictError and is never a terminal value.
  def test_redirect_wait_is_not_validation_and_never_terminal_fails
    with_runner(request_definition) do |store, app, runner|
      thread = "thread.redirect-wait"
      first = runner.deliver({}, thread:, request_id: "request.first")
      # An unresolved effect on the target execution makes the redirect unready.
      store.open_writer(
        thread_id: thread, namespace: [], owner_id: "owner.eff",
        ttl: store.writer_ttl
      ) do |writer|
        writer.effects.prepare(
          execution_id: first.execution_id,
          task_id: "task.blocker",
          call_index: 0,
          operation: "tool.run",
          safety: :read_only,
          request: {"value" => 1}
        )
      end
      runner.submit(
        {"task" => "replace"},
        thread:,
        request_id: "request.redirect",
        operation: :redirect,
        delivery: :redirect
      )
      error = assert_raises(Tamoz::CheckpointConflictError) do
        runner.run_next(thread:, owner_id: "owner.a")
      end
      refute_instance_of Tamoz::StaleRequestError, error
      assert_match(/redirect is waiting/, error.message)
      assert_equal :redirecting,
                   runner.fetch(thread:, request_id: "request.redirect").status
      assert_nil runner.fetch(thread:, request_id: "request.redirect").terminal_error
    end
  end

  # DR4-09: FIFO wedge unblocks — stale requests terminal-fail in order and real work
  # behind them proceeds.
  def test_fifo_wedge_unblocks_stale_requests_in_order_and_real_work_proceeds
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.fifo-wedge"
      runner.deliver({}, thread:, request_id: "request.start")
      tid = task_id_for(app, thread)

      runner.submit(
        {tid => {5 => "stale-a"}},
        thread:, request_id: "request.r1", operation: :resume
      )
      runner.submit(
        {tid => {5 => "stale-b"}},
        thread:, request_id: "request.r2", operation: :resume
      )
      runner.submit(
        {tid => {0 => "current"}},
        thread:, request_id: "request.r3", operation: :resume
      )

      r1 = runner.run_next(thread:, owner_id: "owner.a")
      r2 = runner.run_next(thread:, owner_id: "owner.a")
      r3 = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, r1.status
      assert_equal :failed, r2.status
      assert_equal "resume answer does not match an outstanding task/call index",
                   r1.terminal_error.fetch("reason")
      assert_equal :completed, r3.status
      assert_equal %w[request.start request.r1 request.r2 request.r3],
                   runner.history(thread:).map(&:request_id)
      assert_nil runner.run_next(thread:, owner_id: "owner.a")
    end
  end

  # DR4-10: negative control — a healthy resume is never terminal-failed.
  def test_healthy_resume_is_not_stale
    with_runner(multi_interrupt_definition) do |_store, app, runner|
      thread = "thread.healthy"
      runner.deliver({}, thread:, request_id: "request.start")

      %w[first second third].each_with_index do |answer, index|
        tid = task_id_for(app, thread)
        resumed = runner.deliver(
          {tid => {index => answer}},
          thread:,
          request_id: "request.resume-#{index}",
          operation: :resume
        )
        assert_equal :completed, resumed.status
      end
      assert_equal :completed, app.state(thread:).status
      assert_equal %w[first second third], app.state(thread:).state.fetch(:answers)
    end
  end

  # DR4-11: predicate condition (c) — re-answering an index already present in
  # resume_values is stale. Exercised directly on the shared predicate (the executor
  # never re-pauses at an already-answered index, so the store cannot reach this state
  # through the ordinary flow; the claim path uses the same predicate — DR4-12).
  def test_predicate_condition_c_rejects_an_answer_already_merged
    with_runner(multi_interrupt_definition) do |_store, app, _runner|
      checkpoint = paused_checkpoint(
        interrupts: [interrupt("ask", 0)],
        resume_values: {"ask" => {0 => "already-merged"}}
      )
      request = request_record(operation: :resume, payload: {"ask" => {0 => "new"}})

      assert_equal(
        "resume answer already exists for call index 0",
        app.stale_request_reason(checkpoint, request)
      )
    end
  end

  # DR4-19: the class split — the four precondition sites raise StaleRequestError;
  # the redirect wait, fork-source-missing, and thread-missing stay CheckpointConflictError.
  def test_stale_request_error_covers_exactly_the_four_precondition_sites
    with_runner(request_definition) do |store, app, _runner|
      thread = "thread.class-split"
      app.durable_runner.deliver({}, thread:, request_id: "request.start")

      store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.x",
                        ttl: store.writer_ttl) do |writer|
        # 527 resume-not-paused (latest is completed)
        assert_raises(Tamoz::StaleRequestError) do
          app.__send__(:resume_with_writer, {"t" => {0 => "x"}}, thread:, namespace: [],
                       request_id: "r", concurrency: :inline, context: nil, writer:)
        end
        # 605 continue-no-frontier
        assert_raises(Tamoz::StaleRequestError) do
          app.__send__(:continue_with_writer, thread:, namespace: [],
                       request_id: "r", concurrency: :inline, context: nil, writer:)
        end
        # 567 retry-not-failed
        assert_raises(Tamoz::StaleRequestError) do
          app.__send__(:retry_failed_with_writer, thread:, namespace: [],
                       request_id: "r", concurrency: :inline, context: nil, writer:)
        end
        # 470 invoke-thread-exists (new_execution false on an existing thread)
        assert_raises(Tamoz::StaleRequestError) do
          app.__send__(
            :invoke_with_writer,
            {},
            thread:,
            namespace: [],
            request_id: "r",
            execution_id: "execution.470",
            concurrency: :inline,
            new_execution: false,
            run_context: app.__send__(
              :build_context,
              nil,
              thread:,
              request_id: "r",
              execution_id: "execution.470",
              cancellation: Tamoz::CancellationToken.new,
              emitter: Tamoz::Emitter::Null::INSTANCE
            ),
            writer:
          )
        end
      end

      # 910 thread-does-not-exist stays CheckpointConflictError.
      assert_raises(Tamoz::CheckpointConflictError) do
        app.__send__(:compatible_latest!, "thread.never-existed", namespace: [], writer: nil)
      end
    end
  end

  # DR4-12: one shared predicate serves claim-time AND the execution precondition
  # sites without drift.
  def test_shared_predicate_matches_the_precondition_sites
    with_runner(multi_interrupt_definition) do |store, app, _runner|
      thread = "thread.predicate"
      app.durable_runner.deliver({}, thread:, request_id: "request.start")
      latest = app.state(thread:)
      checkpoint = store.find(
        thread_id: thread, namespace: [], checkpoint_id: latest.checkpoint_id
      )
      tid = checkpoint.interrupts.first.task_id

      paused_req = request_record(operation: :resume, payload: {tid => {0 => "x"}})
      assert_nil app.stale_request_reason(checkpoint, paused_req),
                 "healthy resume must not be stale"
      assert_equal(
        "resume answer does not match an outstanding task/call index",
        app.stale_request_reason(
          checkpoint,
          request_record(operation: :resume, payload: {tid => {9 => "x"}})
        )
      )
      # A resume against a RUNNING checkpoint (the 527 status precondition) is stale
      # even when its answers would match.
      running_checkpoint = checkpoint.with(status: :running)
      assert_equal(
        "latest checkpoint is not paused",
        app.stale_request_reason(
          running_checkpoint,
          request_record(operation: :resume, payload: {tid => {0 => "x"}})
        )
      )
      assert_equal(
        "latest checkpoint is not failed",
        app.stale_request_reason(checkpoint, request_record(operation: :retry, payload: {}))
      )
      assert_equal(
        "latest checkpoint has no runnable frontier",
        app.stale_request_reason(checkpoint, request_record(operation: :continue, payload: {}))
      )
      assert_equal(
        "latest checkpoint is not terminal",
        app.stale_request_reason(checkpoint, request_record(operation: :turn, payload: {}))
      )
      assert_nil app.stale_request_reason(
        checkpoint,
        request_record(operation: :redirect, payload: {})
      ), "redirect is never validated"
    end
  end

  # DR4-13: validator return contract — nil or a bounded string; anything else fails
  # closed with no partial writes.
  def test_claim_validator_return_contract_fails_closed
    with_runner(multi_interrupt_definition) do |store, _app, runner|
      thread = "thread.validator"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"ask" => {0 => "a"}},
        thread:,
        request_id: "request.resume",
        operation: :resume
      )

      [123, "", "control\u0007char", "x" * 513].each_with_index do |bad, index|
        claim = nil
        assert_raises(Tamoz::ConfigurationError) do
          store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.bad#{index}",
                            ttl: store.writer_ttl) do |writer|
            claim = writer.claim_next_request(
              validator: ->(_request, _checkpoint) { bad }
            )
          end
        end
        assert_nil claim
        assert_equal :queued,
                     runner.fetch(thread:, request_id: "request.resume").status,
                     "an invalid validator return must leave the request untouched"
      end

      # A raising validator also fails closed.
      assert_raises(Tamoz::ConfigurationError) do
        store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.raise",
                          ttl: store.writer_ttl) do |writer|
          writer.claim_next_request(
            validator: ->(_request, _checkpoint) { raise "boom" }
          )
        end
      end
      assert_equal :queued, runner.fetch(thread:, request_id: "request.resume").status
    end
  end

  # DR4-14/32: the queued -> failed edge exists ONLY inside the claim transaction; the
  # public fenced transition API still rejects it.
  def test_queued_to_failed_edge_is_only_reachable_inside_the_claim_transaction
    with_runner(multi_interrupt_definition) do |store, _app, runner|
      thread = "thread.edge"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"ask" => {0 => "a"}},
        thread:,
        request_id: "request.resume",
        operation: :resume
      )

      lease = store.adapter.__send__(
        :acquire_lease,
        thread_id: thread,
        namespace: wire.namespace([]),
        owner_id: "owner.public",
        ttl: store.writer_ttl
      )
      begin
        error = assert_raises(Tamoz::CheckpointConflictError) do
          store.requests.__send__(
            :transition_request_without_checkpoint!,
            lease:,
            request_id: "request.resume",
            execution_id: "execution.public",
            action: :failed
          )
        end
        assert_match(/mismatched|cannot transition/, error.message)
      ensure
        store.adapter.__send__(:release_lease, lease)
      end
      assert_equal :queued, runner.fetch(thread:, request_id: "request.resume").status

      # Inside the claim transaction the same request terminal-fails.
      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      assert_equal %i[queued failed],
                   transition_statuses(store, thread, "request.resume")
    end
  end

  # DR4-15: terminal payload shape is canonical, digest-protected, and round-trips
  # through a fresh adapter; a failed request carries no success response.
  def test_terminal_error_payload_shape_round_trips_through_a_fresh_adapter
    Dir.mktmpdir("tamoz-stale-roundtrip") do |directory|
      path = File.join(directory, "tamoz.db")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = multi_interrupt_definition.compile(checkpointer: adapter)
      runner = app.durable_runner
      thread = "thread.roundtrip"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"ask" => {9 => "x"}},
        thread:,
        request_id: "request.stale",
        operation: :resume
      )
      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status
      adapter.close

      reopened = Tamoz::SQLite::Adapter.new(path:)
      reopened_app = multi_interrupt_definition.compile(checkpointer: reopened)
      refetched = reopened_app.checkpointer.fetch_request(
        thread_id: thread, namespace: [], request_id: "request.stale"
      )
      assert_equal :failed, refetched.status
      assert refetched.terminal?
      assert_equal failed.terminal_error, refetched.terminal_error
      assert_equal "failed", refetched.terminal_error.fetch("graph_status")
      assert refetched.terminal_error.fetch("reason").is_a?(String)
      refute refetched.terminal_error.fetch("reason").empty?
      assert_equal(
        {"kind" => "claim_validation", "operation" => "resume"},
        refetched.terminal_error.fetch("evidence")
      )
      assert_nil refetched.response
      reopened.close
    end
  end

  # DR4-16: the claim-time path and the post-claim backstop serialize byte-identical
  # terminal payloads for the same cause.
  def test_claim_time_and_backstop_terminal_payloads_are_byte_identical
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread_a = "thread.payload-a"
      thread_b = "thread.payload-b"

      # Claim-time cause: stale-by-status against a completed checkpoint.
      runner.deliver({}, thread: thread_a, request_id: "request.start")
      tid_a = task_id_for(app, thread_a)
      runner.submit(
        {tid_a => {0 => "a"}},
        thread: thread_a,
        request_id: "request.stale",
        operation: :resume
      )
      advance_to_completed(app, store, thread_a)
      claim_failed = runner.run_next(thread: thread_a, owner_id: "owner.a")

      # Backstop cause: a CLAIMED request failed through the public fenced
      # terminal_fail (the drift net) with the same reason.
      runner.deliver({}, thread: thread_b, request_id: "request.start")
      runner.submit(
        {"ask" => {0 => "b"}},
        thread: thread_b,
        request_id: "request.stale",
        operation: :resume
      )
      claim_without_validation(store, thread_b, "request.stale")
      store.open_writer(thread_id: thread_b, namespace: [], owner_id: "owner.b",
                        ttl: store.writer_ttl) do |writer|
        writer.terminal_fail(
          request_id: "request.stale",
          operation: :resume,
          reason: claim_failed.terminal_error.fetch("reason")
        )
      end
      backstop = runner.fetch(thread: thread_b, request_id: "request.stale")

      assert_equal :failed, backstop.status
      assert_equal claim_failed.terminal_error, backstop.terminal_error
      assert_equal claim_failed.terminal_error.to_json, backstop.terminal_error.to_json
    end
  end

  # DR4-17: the claim-validation transition evidence is recorded exactly once with the
  # reason and the checkpoint the validator saw; no claimed row exists.
  def test_claim_validation_transition_evidence_is_recorded_once
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.evidence"
      runner.deliver({}, thread:, request_id: "request.start")
      latest = app.state(thread:)
      runner.submit(
        {"ask" => {9 => "x"}},
        thread:,
        request_id: "request.stale",
        operation: :resume
      )
      failed = runner.run_next(thread:, owner_id: "owner.evidence")
      assert_equal :failed, failed.status

      rows = nil
      adapter_rows(store, "request.transitions") do |tx|
        rows = tx.rows(
          "test.transitions",
          <<~SQL,
            SELECT transition_index, from_status, to_status, fence, evidence
            FROM tamoz_request_transitions
            WHERE thread_id = ? AND request_id = ?
            ORDER BY transition_index
          SQL
          [thread, "request.stale"]
        )
      end
      assert_equal 2, rows.length
      assert_equal %w[queued failed], [rows[0].fetch(2), rows[1].fetch(2)]
      refute rows.any? { |row| row.fetch(1) == "claimed" },
             "a stale request must never be observably claimed"
      terminal = rows.last
      evidence = JSON.parse(terminal.fetch(4))
      assert_equal "claim_validation", evidence.fetch("kind")
      assert_equal "resume", evidence.fetch("operation")
      assert_equal "resume answer does not match an outstanding task/call index",
                   evidence.fetch("reason")
      assert_equal latest.checkpoint_id, evidence.fetch("checkpoint_id")
      refute_nil terminal.fetch(3), "the claimer's lease fence must be recorded"
    end
  end

  # DR4-18: a terminal-failed request is never re-claimable; identical-input duplicate
  # delivery returns the prior outcome; different-input duplicates still conflict.
  def test_terminal_failed_request_is_never_reclaimed_and_duplicates_return_prior_outcome
    with_runner(multi_interrupt_definition) do |store, _app, runner|
      thread = "thread.durable-idempotent"
      runner.deliver({}, thread:, request_id: "request.start")
      payload = {"ask" => {9 => "x"}}
      runner.submit(payload, thread:, request_id: "request.stale", operation: :resume)
      failed = runner.run_next(thread:, owner_id: "owner.a")
      assert_equal :failed, failed.status

      assert_nil runner.run_next(thread:, owner_id: "owner.b")
      duplicate = runner.deliver(
        payload, thread:, request_id: "request.stale", operation: :resume
      )
      assert_equal :failed, duplicate.status
      assert_equal failed.terminal_error, duplicate.terminal_error
      assert_equal 1,
                   transition_statuses(store, thread, "request.stale").count(:failed),
                   "duplicate delivery must not add a terminal transition"
      assert_raises(Tamoz::CheckpointConflictError) do
        runner.submit(
          {"ask" => {9 => "different"}},
          thread:, request_id: "request.stale", operation: :resume
        )
      end
    end
  end

  # DR4-24: recover validates — a recovered stale claimed request terminal-fails
  # INSIDE the recover transaction, never re-executes.
  def test_recover_of_a_stale_claimed_request_terminal_fails
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.recover-stale"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"ask" => {0 => "a"}},
        thread:,
        request_id: "request.claimed",
        operation: :resume
      )
      claimed = claim_without_validation(store, thread, "request.claimed")
      assert_equal :claimed, claimed.status
      advance_to_completed(app, store, thread)

      recovered = runner.recover(thread:, request_id: "request.claimed",
                                 owner_id: "owner.recover")
      assert_equal :failed, recovered.status
      assert_equal "latest checkpoint is not paused",
                   recovered.terminal_error.fetch("reason")
      assert_equal %i[queued claimed failed],
                   transition_statuses(store, thread, "request.claimed")
      assert_equal :completed, app.state(thread:).status
    end
  end

  # DR4-25: recover of a HEALTHY claimed request still executes normally (no
  # over-validation).
  def test_recover_of_a_healthy_claimed_request_executes_normally
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.recover-healthy"
      paused = runner.deliver({}, thread:, request_id: "request.start")
      tid = task_id_for(app, thread)
      runner.submit(
        {tid => {0 => "a"}},
        thread:,
        request_id: "request.claimed",
        operation: :resume
      )
      claimed = claim_without_validation(store, thread, "request.claimed")
      assert_equal :claimed, claimed.status

      recovered = runner.recover(thread:, request_id: "request.claimed",
                                 owner_id: "owner.recover")
      assert_equal :completed, recovered.status
      assert_equal paused.execution_id, recovered.execution_id
      assert_equal :paused, app.state(thread:).status
      # Drive the recovered execution to completion: the merged answer applies.
      advance_to_completed(app, store, thread)
      assert_equal %w[a advance advance], app.state(thread:).state.fetch(:answers)
    end
  end

  # F3/F5: a kill inside the claim transaction (simulated by a fault-injector raise,
  # which rolls back the exact same SQLite transaction a SIGKILL would) leaves the
  # request queued with NO partial evidence; the restart drain re-validates and
  # terminal-fails exactly once.
  def test_kill_inside_the_claim_transaction_leaves_queued_or_failed_never_partial
    %i[after_begin before_commit].each do |seam|
      Dir.mktmpdir("tamoz-stale-kill") do |directory|
        path = File.join(directory, "tamoz.db")
        claims = 0
        fired = false
        fault = lambda do |point, metadata|
          next unless metadata.fetch("operation") == "request.claim"
          next unless point == seam

          claims += 1
          next unless claims == 2 # arm only on the stale request's claim
          next if fired

          fired = true
          raise "crash at claim seam"
        end
        adapter = Tamoz::SQLite::Adapter.new(path:, fault_injector: fault)
        app = multi_interrupt_definition.compile(checkpointer: adapter)
        runner = app.durable_runner
        thread = "thread.kill-#{seam}"
        runner.deliver({}, thread:, request_id: "request.start")
        runner.submit(
          {"ask" => {9 => "x"}},
          thread:,
          request_id: "request.stale",
          operation: :resume
        )

        assert_raises(RuntimeError) do
          runner.run_next(thread:, owner_id: "owner.killed")
        end
        assert fired

        # Atomicity: the request is still queued with no terminal evidence.
        current = runner.fetch(thread:, request_id: "request.stale")
        assert_equal :queued, current.status
        assert_nil current.terminal_error
        rows = nil
        adapter_rows(adapter, "request.transitions") do |tx|
          rows = tx.rows(
            "test.transitions",
            <<~SQL,
              SELECT from_status, to_status FROM tamoz_request_transitions
              WHERE thread_id = ? AND request_id = ?
            SQL
            [thread, "request.stale"]
          )
        end
        assert_equal [[nil, "queued"]], rows,
                     "a kill in the claim tx must leave no partial transition"

        # The restart drain re-validates and terminal-fails cleanly, exactly once.
        failed = runner.run_next(thread:, owner_id: "owner.restart")
        assert_equal :failed, failed.status
        rows = nil
        adapter_rows(adapter, "request.transitions") do |tx|
          rows = tx.rows(
            "test.transitions",
            <<~SQL,
              SELECT from_status, to_status FROM tamoz_request_transitions
              WHERE thread_id = ? AND request_id = ?
            SQL
            [thread, "request.stale"]
          )
        end
        assert_equal [[nil, "queued"], %w[queued failed]], rows
        assert_nil runner.run_next(thread:, owner_id: "owner.restart2")
        adapter.close
      end
    end
  end

  # DR4-A1: two owners draining the same stale request — the lease serializes the
  # claim; the second owner observes the terminal outcome, never a double write.
  def test_two_owner_claim_race_observes_exactly_one_terminal_outcome
    with_runner(multi_interrupt_definition) do |store, _app, runner|
      thread = "thread.race"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"ask" => {9 => "x"}},
        thread:,
        request_id: "request.stale",
        operation: :resume
      )

      first = runner.run_next(thread:, owner_id: "owner.first")
      second = runner.run_next(thread:, owner_id: "owner.second")
      assert_equal :failed, first.status
      assert_nil second
      rows = nil
      adapter_rows(store, "request.transitions") do |tx|
        rows = tx.rows(
          "test.transitions",
          <<~SQL,
            SELECT from_status, to_status FROM tamoz_request_transitions
            WHERE thread_id = ? AND request_id = ?
          SQL
          [thread, "request.stale"]
        )
      end
      assert_equal [[nil, "queued"], %w[queued failed]], rows,
                   "exactly one terminal transition across both owners"
    end
  end

  # DR4-A4: a stale request never takes down a second unrelated thread in the same
  # drain loop.
  def test_a_stale_request_does_not_poison_an_unrelated_thread
    with_runner(multi_interrupt_definition) do |_store, app, runner|
      thread_one = "thread.isolated-one"
      thread_two = "thread.isolated-two"
      runner.deliver({}, thread: thread_two, request_id: "request.start")
      runner.deliver({}, thread: thread_one, request_id: "request.start")
      runner.submit(
        {"ask" => {9 => "x"}},
        thread: thread_one,
        request_id: "request.stale",
        operation: :resume
      )

      failed = runner.run_next(thread: thread_one, owner_id: "owner.one")
      assert_equal :failed, failed.status
      # Thread two drains cleanly and its work is untouched.
      assert_nil runner.run_next(thread: thread_two, owner_id: "owner.two")
      assert_equal :paused, app.state(thread: thread_one).status
      assert_equal :paused, app.state(thread: thread_two).status
    end
  end

  # D3 / DR4-29: the CLI drain renders the typed reason from terminal_error once and
  # never re-attempts the failed request; the drain terminates cleanly.
  def test_cli_drain_renders_the_typed_reason_and_does_not_re_resume
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.cli"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"any" => {9 => "x"}},
        thread:,
        request_id: "request.stale",
        operation: :resume
      )

      fake = FakeSession.new(app, status: :paused, interrupts: [])
      out = StringIO.new
      err = StringIO.new
      cli = Tamoz::Agent::CLI.new(
        out:,
        err:,
        input: StringIO.new,
        env: {}
      )
      cli.send(
        :drain_to_terminal,
        fake,
        thread_id: thread,
        owner_id: "owner.cli",
        options: {}
      )

      assert_match(/stale resume request request\.stale/, err.string)
      assert_match(/does not match an outstanding task\/call index/, err.string)
      assert_empty fake.resume_calls, "the failed request must never be re-resumed"
      assert_empty fake.continue_calls
      assert_empty out.string
    end
  end

  # D3 variant: a stale request already consumed by a `deliver`-style run_next (the
  # `tamoz resume` flow) is rendered from the thread history by the drain, once per
  # request id, and is never re-resumed.
  def test_cli_drain_renders_a_deliver_consumed_stale_failure_from_history
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.cli-history"
      runner.deliver({}, thread:, request_id: "request.start")
      runner.submit(
        {"any" => {9 => "x"}},
        thread:,
        request_id: "request.stale",
        operation: :resume
      )
      # The stale request is terminal-failed by an internal run_next, exactly as a
      # `deliver` inside session.resume would consume it.
      failed = runner.run_next(thread:, owner_id: "owner.internal")
      assert_equal :failed, failed.status

      fake = FakeSession.new(app, status: :paused, interrupts: [])
      out = StringIO.new
      err = StringIO.new
      cli = Tamoz::Agent::CLI.new(
        out:,
        err:,
        input: StringIO.new,
        env: {}
      )
      cli.send(
        :drain_to_terminal,
        fake,
        thread_id: thread,
        owner_id: "owner.cli",
        options: {}
      )

      assert_match(/stale resume request request\.stale/, err.string)
      assert_match(/does not match an outstanding task\/call index/, err.string)
      # Rendering is once per request id: a second drain renders nothing new.
      err.rewind
      err.truncate(0)
      cli.send(
        :drain_to_terminal,
        fake,
        thread_id: thread,
        owner_id: "owner.cli2",
        options: {}
      )
      assert_empty err.string
      assert_empty fake.resume_calls
    end
  end

  # DR-4 critic hardening: in the durable claim->execute window the checkpoint can
  # change between claim and merge (lease expiry + an owner-B write), so an
  # answer/index mismatch at the DURABLE merge must surface as StaleRequestError
  # (the runner's backstop then terminal-fails it) — never as an escaping
  # InvalidUpdateError, the D-6 signature. The EPHEMERAL path keeps
  # InvalidUpdateError for direct caller bugs (pinned by graph_interrupt_test).
  def test_durable_resume_merge_mismatch_is_stale_request_error
    with_runner(multi_interrupt_definition) do |store, app, runner|
      thread = "thread.drift-window"
      runner.deliver({}, thread:, request_id: "request.start")
      tid = task_id_for(app, thread)
      runner.submit(
        {tid => {0 => "a"}},
        thread:,
        request_id: "request.pause",
        operation: :resume
      )
      runner.run_next(thread:, owner_id: "owner.a") # pause with an interrupt set

      store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.b", ttl: 30) do |writer|
        error = assert_raises(Tamoz::StaleRequestError) do
          app.send(
            :resume_with_writer,
            {"unknown-task" => {0 => "x"}},
            thread:,
            namespace: [],
            request_id: "request.drift",
            concurrency: :inline,
            context: nil,
            writer:,
            durable_request_id: "request.drift"
          )
        end
        assert_match(/does not match an outstanding task\/call index/, error.message)
        refute_includes error.class.ancestors, Tamoz::InvalidUpdateError
      end
    end
  end

  private

  View = Struct.new(
    :status, :interrupts, :execution_id, :state, :terminal, :blocked,
    :thread_id, :checkpoint_id, :sequence, :effect_receipts, :accepted_plan,
    keyword_init: true
  )

  class FakeSession
    attr_reader :app, :resume_calls, :continue_calls

    def initialize(app, status:, interrupts:)
      @app = app
      @status = status
      @interrupts = interrupts
      @resume_calls = []
      @continue_calls = []
    end

    def view(thread:)
      View.new(
        status: @status,
        interrupts: @interrupts,
        execution_id: "execution.view",
        state: {},
        terminal: nil,
        blocked: nil,
        thread_id: thread,
        checkpoint_id: "checkpoint.view",
        sequence: 1,
        effect_receipts: [],
        accepted_plan: nil
      )
    end

    def resume(answers, thread:, request_id:, owner_id:, context: nil)
      @resume_calls << request_id
      nil
    end

    def continue(thread:, request_id:, owner_id:, context: nil)
      @continue_calls << request_id
      nil
    end
  end

  def with_runner(definition)
    Dir.mktmpdir("tamoz-stale") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      app = definition.compile(checkpointer: adapter)
      # The first yielded value is the graph-bound checkpointer (the store); the raw
      # adapter is reachable through `store.adapter`.
      yield app.checkpointer, app, app.durable_runner
      adapter.close
    end
  end

  def request_definition
    Tamoz.graph(name: "stale-request", version: "1") do
      state :input, default: ""
      state :seen, reduce: :append, default: []
      node(
        :record,
        implementation_name: "stale.record",
        version: "1"
      ) { |state, _context| {seen: [state.fetch(:input)]} }
      edge Tamoz::START, :record
      edge :record, Tamoz::END
    end
  end

  def multi_interrupt_definition
    Tamoz.graph(name: "stale-multi-interrupt", version: "1") do
      state :answers, reduce: :append, default: []
      node(
        :ask,
        implementation_name: "stale.ask",
        version: "1"
      ) do |_state, context|
        values = 3.times.map { |index| Tamoz.interrupt({"question" => index.to_s}, context) }
        {answers: values}
      end
      edge Tamoz::START, :ask
      edge :ask, Tamoz::END
    end
  end

  def flaky_definition
    calls = Hash.new(0)
    Tamoz.graph(name: "stale-flaky", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :flaky,
        implementation_name: "stale.flaky",
        version: "1"
      ) do |_state, _context|
        calls[:runs] += 1
        raise "first attempt fails" if calls[:runs] == 1

        {events: ["ok"]}
      end
      edge Tamoz::START, :flaky
      edge :flaky, Tamoz::END
    end
  end

  # Owner B advances a paused thread directly (the two-owner shape): resume under a
  # fresh lease, leaving the queued request untouched.
  def advance_resume(app, store, thread, answers)
    store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.advance",
                      ttl: store.writer_ttl) do |writer|
      app.__send__(
        :resume_with_writer,
        answers,
        thread:,
        namespace: [],
        request_id: "request.advance",
        concurrency: :inline,
        context: nil,
        writer:,
        durable_request_id: nil,
        mark_request_running: false
      )
    end
  end

  # Owner B drives a paused thread to completion one interrupt at a time.
  def advance_to_completed(app, store, thread)
    5.times do
      state = app.state(thread:)
      return state.status unless state.status == :paused

      interrupt = state.interrupts.first
      advance_resume(
        app,
        store,
        thread,
        {interrupt.task_id => {interrupt.call_index => "advance"}}
      )
    end
    app.state(thread:).status
  end

  def task_id_for(app, thread)
    app.state(thread:).interrupts.first.task_id
  end

  def advance_retry(app, store, thread)
    store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.advance",
                      ttl: store.writer_ttl) do |writer|
      app.__send__(
        :retry_failed_with_writer,
        thread:,
        namespace: [],
        request_id: "request.advance",
        concurrency: :inline,
        context: nil,
        writer:,
        durable_request_id: nil,
        mark_request_running: false
      )
    end
  end

  def claim_without_validation(store, thread, request_id)
    claimed = nil
    store.open_writer(thread_id: thread, namespace: [], owner_id: "owner.claim",
                      ttl: store.writer_ttl) do |writer|
      claimed = writer.claim_next_request
    end
    assert_equal request_id, claimed.request_id
    claimed
  end

  def transition_statuses(store, thread, request_id)
    statuses = nil
    adapter_rows(store, "request.transitions") do |tx|
      rows = tx.rows(
        "test.transitions",
        <<~SQL,
          SELECT from_status, to_status FROM tamoz_request_transitions
          WHERE thread_id = ? AND request_id = ?
          ORDER BY transition_index
        SQL
        [thread, request_id]
      )
      statuses = rows.map { |row| row.fetch(1).to_sym }
    end
    statuses
  end

  def adapter_rows(source, operation)
    adapter = source.respond_to?(:adapter) ? source.adapter : source
    adapter.__send__(:read, operation: "test.#{operation}") do |tx|
      yield tx
    end
  end

  def wire
    Tamoz::SQLite.const_get(:Wire, false)
  end

  def interrupt(task_id, call_index)
    Tamoz::Graph::Interrupt.new(
      task_id:,
      call_index:,
      descriptor: {"kind" => "clarify", "question" => "?"}
    )
  end

  def paused_checkpoint(interrupts:, resume_values:)
    Tamoz::Graph::Checkpoint.new(
      format_version: 1,
      id: "checkpoint.predicate",
      sequence: 1,
      thread_id: "thread.predicate",
      namespace: [],
      execution_id: "execution.predicate",
      parent_id: nil,
      graph_name: "stale-multi-interrupt",
      graph_version: "1",
      definition_digest: "digest.predicate",
      status: :paused,
      logical_step: 1,
      state: {},
      state_bytes: "",
      frontier: [],
      pending: {},
      interrupts:,
      resume_values:,
      attempts: {},
      failure: nil,
      total_tasks: 1
    )
  end

  def request_record(operation:, payload:)
    Tamoz::Graph::RequestRecord.new(
      thread_id: "thread.predicate",
      namespace: [],
      request_id: "request.predicate",
      enqueue_sequence: 0,
      input_digest: "digest",
      operation:,
      delivery_mode: :queue,
      status: :queued,
      payload:,
      execution_id: nil,
      target_execution_id: nil,
      cancellation_generation: nil,
      checkpoint_id: nil,
      response: nil,
      terminal_error: nil,
      retryable: nil,
      created_at_ms: 0,
      updated_at_ms: 0
    )
  end
end
