# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require "set"

require_relative "terminal_progress"

module Tamoz
  module Agent
    # The foreground worker.
    #
    # It is a COMPOSITION, not an engine. Every durable decision it makes is made
    # by something that already existed and was already proven: the request inbox
    # claims work under a fenced lease, `DurableRunner` executes and recovers,
    # `Session` deliberates, the schedule store materializes occurrences
    # atomically. The worker's whole job is to decide *what to look at next* and
    # to stay out of the way of the guarantees underneath.
    #
    # Two rules shape everything here:
    #
    #   1. Being unattended is never a reason to do more. A turn that would stop
    #      and ask a human when a human was watching stops and asks when nobody
    #      is. The worker records the question durably and moves on; it never
    #      answers on the human's behalf. There is no headless auto-approval path
    #      in this file, and there must never be one.
    #
    #   2. Idle costs nothing. When there is no work the worker sleeps on its
    #      cancellation token rather than spinning, and wakes immediately on a
    #      signal.
    #
    # Supervision is somebody else's job. This is a plain foreground process that
    # exits 0 on SIGINT/SIGTERM after finishing what it had in hand, which is all
    # launchd, systemd, Docker or runit need from it.
    class Worker
      DEFAULT_POLL_INTERVAL = 1.0
      DEFAULT_CONCURRENCY = 1
      DEFAULT_BATCH = 50

      # Why the worker stopped looking at a thread. `:progressed` is the only
      # value that counts as work for the idle/backoff decision.
      PROGRESSED = :progressed
      PARKED = :parked
      IDLE = :idle

      attr_reader :processed, :parked

      def initialize(
        runtime:,
        session_builder:,
        emitter:,
        once: false,
        concurrency: DEFAULT_CONCURRENCY,
        poll_interval: DEFAULT_POLL_INTERVAL,
        batch: DEFAULT_BATCH,
        cancellation: nil,
        recorder: Tamoz::Observability::Recorder::Null::INSTANCE,
        content_policy: Tamoz::Observability::ContentPolicy::NONE
      )
        @runtime = runtime
        @session_builder = session_builder
        @emitter = emitter
        @once = once
        @concurrency = Integer(concurrency).clamp(1, 32)
        @poll_interval = Float(poll_interval)
        @batch = Integer(batch)
        @cancellation = cancellation || Tamoz::CancellationToken.new
        @observability = Tamoz::Observability::Producer.new(recorder:, policy: content_policy)
        @model_effect_keys = Set.new
        @model_effect_monitor = Mutex.new
        @milestone_sequences = {}
        @processed = 0
        # Threads waiting on a human. Keyed by thread so a parked thread neither
        # spins the loop nor blocks its neighbours; the signature lets an arriving
        # response un-park it without the worker having to be told.
        @parked = {}
        @monitor = Mutex.new
      end

      def stop!(reason) = @cancellation.cancel!(reason)
      def stopping? = @cancellation.cancelled?

      def run
        emit("worker.started",
             runtime: @runtime.path,
             concurrency: @concurrency,
             once: @once,
             poll_interval: @poll_interval)
        reason = "idle"
        loop do
          if stopping?
            reason = "signal"
            break
          end

          worked = poll_once
          if @once
            break unless worked
          elsif !worked
            reason = "signal" if sleep_until_due == :cancelled
            break if stopping?
          end
        end
        reason
      ensure
        # Grants never outlive the worker that bound their profile session.
        begin
          @runtime.close_approval_session
        rescue StandardError
          nil
        end
        emit("worker.stopped",
             reason: reason || "error",
             processed: @processed,
             parked: @parked.size)
      end

      # One pass: turn due schedules into queued requests, then advance whatever
      # is queued. Returns whether anything moved, which is the only input to the
      # idle decision.
      def poll_once
        @runtime.sync_approval_policy
        switched = drain_mode_switches
        enforce_ask_deadlines
        reconciled = reconcile_child_requests
        materialized = materialize_due_schedules
        advanced = advance_pending_threads
        (reconciled + materialized + switched + advanced).positive?
      end

      private

      def reconcile_child_requests
        @runtime.reconcile_child_requests(limit: @batch).length
      rescue WorkerRuntime::StoreUnavailableError => error
        emit('worker.error', reason: error.message)
        0
      end

      # ---------------------------------------------------------------- schedules

      # The schedule store claims a due occurrence and enqueues its request in ONE
      # transaction. The worker does not get to see a half-claimed occurrence, so
      # "exactly one logical occurrence" is the store's guarantee, not a race the
      # worker has to win.
      def materialize_due_schedules
        store = @runtime.schedule_store
        return 0 unless store

        claimed = store.materialize_due(
          now: Time.now.to_i,
          owner: owner_id,
          lease_for: 60,
          limit: @batch,
          # One scan sees many schedules, each with its own task, so the template
          # is resolved per schedule. The task text comes from the operator's
          # runtime store — the schedule's `payload_ref` addresses it — and never
          # from the payload of whatever enqueued it.
          request_template: ->(schedule) { {"task" => task_for(schedule)} },
          # The session's payload IS its graph state and rejects undeclared keys;
          # occurrence provenance stays on the occurrence row where it is queryable.
          include_provenance: false,
          current_grant: @runtime.worker_grant
        )
        claimed.each do |occurrence|
          emit("schedule.materialized",
               schedule_id: occurrence.schedule_id,
               occurrence_id: occurrence.occurrence_id,
               request_id: occurrence.request_id)
        end
        claimed.length
      rescue Tamoz::Scheduler::SchedulerError, WorkerRuntime::StoreUnavailableError => error
        # A store that cannot answer materializes NOTHING this pass. The pass is
        # reported and retried, which is the honest shape: the alternative — the
        # old swallow-to-nil in the runtime — enqueued an occurrence with no
        # task behind it.
        emit("schedule.error", reason: error.message)
        0
      end

      # A schedule whose stored task has gone missing enqueues nothing runnable;
      # an empty task is refused loudly rather than becoming an empty turn.
      def task_for(schedule)
        task = @runtime.schedule_payload(schedule.id)
        if task.nil? || task.strip.empty?
          raise Tamoz::Scheduler::SchedulerError,
                "schedule #{schedule.id} has no stored task payload"
        end

        task
      end

      # ------------------------------------------------------------------ inbox

      def advance_pending_threads
        actionable = actionable_entries
        return 0 if actionable.empty?

        progressed_results(advance_entries(actionable))
      end

      def actionable_entries
        work_list.reject { |entry| parked?(entry) && !resume_queued?(entry) }
      rescue WorkerRuntime::StoreUnavailableError => error
        # The work list could not be read. That is reported and retried on the
        # next pass — it is NOT an empty inbox, and the difference has to be
        # visible or a sick store looks exactly like a quiet one.
        emit("worker.error", reason: error.message)
        []
      end

      def advance_entries(entries)
        pool = Tamoz::Pool.for(
          @concurrency > 1 ? :threads : :inline,
          size: @concurrency,
          max_tasks: @batch,
          cancellation: @cancellation
        )
        pool.map(entries) { |entry| advance_thread(entry) }
      end

      def progressed_results(results)
        results.count { |result| value_of(result) == PROGRESSED }
      end

      # Where there is work to do.
      #
      # The inbox is only half the answer. A turn that stopped to ask a human
      # COMPLETED its request — the request ran; it is the session that is paused
      # — so an unfinished occurrence can leave the inbox entirely. The durable
      # open-occurrence records are the other half, and they survive a restart,
      # which an in-memory set would not.
      #
      # An open occurrence wins the thread's slot over anything queued: a turn
      # claimed while the latest checkpoint is non-terminal is stale by
      # definition, so a message that arrives mid-turn or mid-approval must WAIT
      # behind the occurrence that is still owed a settle — not be failed for
      # arriving early. Once the occurrence closes, the queued request claims
      # against a terminal checkpoint and runs.
      def work_list
        open = @runtime.open_occurrences(limit: @batch)
        busy = open.map { |record| record.fetch(:thread_id) }.to_set
        queued = @runtime.checkpoints.pending_threads(limit: @batch).reject do |entry|
          busy.include?(entry.fetch(:thread_id))
        end
        open.map do |record|
          {
            thread_id: record.fetch(:thread_id),
            namespace: [],
            head_request_id: record.fetch(:occurrence_id),
            head_status: :open,
            enqueue_sequence: -1
          }
        end + queued
      end

      # Everything that can go wrong with one thread is contained to that thread.
      # A thread that raises is recorded and left alone; it must never take the
      # worker down or stall its neighbours.
      def advance_thread(entry)
        thread_id = entry.fetch(:thread_id)
        occurrence_id = entry.fetch(:head_request_id)
        session = @session_builder.call(thread_id)
        return IDLE unless session

        advance_entry(entry, session, thread_id:, occurrence_id:)
      rescue Tamoz::RecursionLimitError => error
        # The graph refused to take another super-step because the profile's
        # `steps` budget is spent. This is a STOP, not a failure: the work was
        # well-formed and the ceiling did its job, so it is reported as its own
        # typed event and recorded durably for `tamoz status`.
        budget_exhausted(entry, budget: "steps", detail: error.message, session:)
      rescue StandardError => error
        handle_thread_failure(entry, error)
      end

      def advance_entry(entry, session, thread_id:, occurrence_id:)
        case entry.fetch(:head_status)
        when :queued
          claim_and_run(session, thread_id:, occurrence_id:)
        when :claimed, :running, :redirecting, :open
          advance_nonterminal_entry(entry, session, thread_id:, occurrence_id:)
        else
          IDLE
        end
      end

      def advance_nonterminal_entry(entry, session, thread_id:, occurrence_id:)
        view = view_of(session, thread_id)
        return resume_paused_entry(entry, session, thread_id:, occurrence_id:, view:) if paused_view?(view)
        return advance_open_occurrence(session, thread_id:, occurrence_id:, view:) if entry.fetch(:head_status) == :open

        recover(session, thread_id:, occurrence_id:)
      end

      def paused_view?(view)
        view && view.status == :paused && !view.interrupts.empty?
      end

      def resume_paused_entry(entry, session, thread_id:, occurrence_id:, view:)
        return run_queued_resume(session, thread_id:, occurrence_id:) if
          queued_resume_request(thread_id, occurrence_id)

        digest = interrupt_digest(view)
        decision = @runtime.pending_decision(
          thread_id, occurrence_id, interrupt_digest: digest, now: Time.now.utc
        )
        return park(entry, view, reason: pause_reason(view)) && PARKED if decision.nil?

        apply_decision(session, thread_id:, occurrence_id:, view:, decision:)
      end

      def queued_resume_request(thread_id, occurrence_id)
        return unless @runtime.respond_to?(:checkpoints)

        @runtime.checkpoints.request_history(thread_id:).find do |request|
          request.status == :queued && request.operation == :resume &&
            Tamoz::Comms::ClarificationAnswerRequest.target_id(request.request_id) == occurrence_id
        end
      end

      def resume_queued?(entry)
        entry.fetch(:head_status) == :open &&
          queued_resume_request(entry.fetch(:thread_id), entry.fetch(:head_request_id))
      end

      def run_queued_resume(session, thread_id:, occurrence_id:)
        unpark(thread_id)
        request = session.app.durable_runner.run_next(thread: thread_id, owner_id: owner_id)
        settle_schedule_occurrence(session, thread_id:, occurrence_id:, request:)
        settle(session, thread_id:, occurrence_id:, request:)
      end

      def advance_open_occurrence(session, thread_id:, occurrence_id:, view:)
        return claim_and_run(session, thread_id:, occurrence_id:) unless view
        return settle(session, thread_id:, occurrence_id:) if %i[completed failed blocked].include?(view.status)

        recover(session, thread_id:, occurrence_id:)
      end

      def handle_thread_failure(entry, error)
        thread_id = entry.fetch(:thread_id)
        occurrence_id = entry.fetch(:head_request_id)
        terminal_request = entry.fetch(:head_status) == :queued
        settle_child_error(thread_id, error) if terminal_request
        close_failed_occurrence(thread_id, occurrence_id) if terminal_request
        emit("request.failed",
             thread: thread_id,
             request_id: occurrence_id,
             duration_ms: @runtime.occurrence_age_milliseconds(thread_id),
             reason: "#{error.class}: #{error.message}")
        if terminal_request
          begin
            @runtime.durably_fail_request(thread_id, occurrence_id, reason: bounded_reason(error))
            notify_sink(thread_id, "request.failed", crashed_text(error), request_id: occurrence_id)
          rescue StandardError
            nil
          end
          park(entry, nil, reason: "failed")
        else
          unpark(thread_id)
        end
        PARKED
      end

      def close_failed_occurrence(thread_id, occurrence_id)
        close_occurrence(thread_id, occurrence_id)
      rescue StandardError => error
        emit('worker.error', reason: "failed occurrence cleanup: #{error.message}")
      end

      # Closing an occurrence ends its milestone sequence: the map entry is
      # dropped so per-request sequence state never accumulates across turns.
      def close_occurrence(thread_id, request_id)
        @monitor.synchronize { @milestone_sequences.delete(request_id) }
        @runtime.close_occurrence(thread_id)
      end

      # Which budget, if any, this thread has spent. Returns nil when the profile
      # sets no enforceable budget — a profile that never asked for a ceiling
      # does not silently acquire one.
      def exhausted_budget(thread_id)
        budgets = @runtime.thread_budgets(thread_id)
        return nil if budgets.nil? || budgets.empty?

        usage = @runtime.budget_usage(thread_id)
        %w[model_calls wall_clock_seconds].each do |name|
          limit = budgets[name]
          next unless limit.is_a?(Numeric) && limit.positive?

          spent = usage.fetch(name, 0)
          next unless spent >= limit

          return {budget: name, detail: "#{name} #{spent} reached the configured limit #{limit}"}
        end
        nil
      end

      # Durable and observable, in that order. The record is written before the
      # event is emitted, so a worker that dies between the two still leaves an
      # operator able to see why the occurrence stopped.
      def budget_exhausted(entry, budget:, detail:, session: nil)
        thread_id = entry.fetch(:thread_id)
        occurrence_id = entry.fetch(:head_request_id)
        duration_ms = @runtime.occurrence_age_milliseconds(thread_id)
        settle_child_error(thread_id, RuntimeError.new("budget_exhausted: #{budget}: #{detail}"))
        @runtime.record_budget_exhaustion(thread_id, occurrence_id, budget:, detail:)
        view = session && view_of(session, thread_id)
        notify_sink(
          thread_id,
          "request.stopped",
          stop_text(view, reason: 'budget_exhausted', budget:),
          request_id: occurrence_id
        )
        # A budget stop is TERMINAL for the occurrence, so the record is closed.
        # Parking would only be in-memory: the next worker process would have an
        # empty park map, re-examine the same occurrence and stop it again, and
        # the operator would collect one stop event per poll forever. Raising the
        # ceiling and re-queueing is the deliberate way to continue, which is the
        # right amount of friction for work that already spent its budget.
        close_occurrence(thread_id, occurrence_id)
        unpark(thread_id)
        emit("request.stopped",
             thread: thread_id,
             request_id: occurrence_id,
             reason: "budget_exhausted",
             budget:,
             detail:,
             duration_ms:)
        PROGRESSED
      end

      # Deliver a recorded human decision to the paused turn.
      #
      # The answers are built from the interrupts the session is ACTUALLY waiting
      # on, and every one of them carries the same recorded decision. The worker
      # supplies no value of its own: it is a courier, not a decision-maker.
      #
      # The claim is a fenced compare-and-set, so a concurrent claimer loses and
      # this thread stays parked; the resume request id is DERIVED from the
      # decision, so a crash between enqueue and consumption repeats the same
      # inbox request instead of duplicating the resume (invariant 23).
      def apply_decision(session, thread_id:, occurrence_id:, view:, decision:)
        now = Time.now.utc
        decision_id = decision.decision_id
        claim = @runtime.claim_decision(
          decision_id, owner: owner_id,
                       fence: Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond), now:
        )
        return park({thread_id:, head_request_id: occurrence_id}, view) && PARKED unless claim == :claimed

        granted = decision.granted?
        resolve_approval_asks(view.interrupts, answer: granted ? :approve : :deny, scope: granted ? :once : nil)
        answers = answers_for(view.interrupts, granted)

        conclude_resolution(session,
                            thread_id: thread_id, occurrence_id: occurrence_id, view: view,
                            granted: granted, actor: decision.actor_id,
                            message: granted ? 'Approved.' : 'Denied.',
                            resume_request_id: decision.resume_request_id, answers: answers,
                            consume_decision_id: decision_id, consumed_at: now)
      end

      # One settle contract for every resolution channel (operator press,
      # timeout denial): announce, notify, unpark, resume, then reconcile the
      # schedule and terminal state.
      def conclude_resolution(session, thread_id:, occurrence_id:, view:, granted:, actor:, message:, resume_request_id:, answers:, consume_decision_id: nil, consumed_at: nil)
        event = granted ? 'request.approved' : 'request.denied'
        emit(event, thread: thread_id, request_id: occurrence_id, actor: actor,
                    observability: {execution_id: view.execution_id})
        notify_sink(thread_id, event, message, request_id: occurrence_id)
        unpark(thread_id)
        request = session.resume(answers, thread: thread_id, request_id: resume_request_id, owner_id: owner_id)
        @runtime.consume_decision(consume_decision_id, now: consumed_at) if consume_decision_id
        settle_schedule_occurrence(session, thread_id:, occurrence_id:, request:)
        settle(session, thread_id:, occurrence_id:)
      end

      # An approval interrupt takes a boolean; a clarification takes text. A
      # denial answers "no" to an approval, and refuses to invent prose for a
      # question only a human can answer.
      def answer_for(interrupt, granted)
        descriptor = interrupt.descriptor || {}
        case descriptor["kind"]
        when "approve_tool" then granted
        else granted ? "" : nil
        end
      end

      # The engine is the resolution authority: the journaled verdict and any
      # minted grant both come from these calls (replay-safe).
      def resolve_approval_asks(interrupts, answer:, scope:)
        interrupts.each do |interrupt|
          descriptor = interrupt.descriptor || {}
          asked = descriptor['decision'] if descriptor['kind'] == 'approve_tool'
          next unless asked

          @runtime.approval_engine.resolve(decision_id: asked.fetch('id'), answer:, scope:)
        end
      end

      def answers_for(interrupts, granted)
        interrupts.each_with_object({}) do |interrupt, answers|
          (answers[interrupt.task_id] ||= {})[interrupt.call_index] = answer_for(interrupt, granted)
        end
      end

      def claim_and_run(session, thread_id:, occurrence_id:)
        emit("request.claimed", thread: thread_id, request_id: occurrence_id)
        start_child_task(thread_id)
        # Durable BEFORE execution: a crash between here and the first checkpoint
        # must still leave a record that this occurrence was started.
        @runtime.open_occurrence(thread_id, occurrence_id)
        notify_milestone(thread_id, "request.claimed", occurrence_id, phase: "claimed")
        request = session.app.durable_runner.run_next(thread: thread_id, owner_id: owner_id)
        observe_cancellation(request, thread_id:)
        settle_schedule_occurrence(session, thread_id:, occurrence_id:, request:)
        settle(session, thread_id:, occurrence_id:, request:)
      end

      def start_child_task(thread_id)
        child = @runtime.child_task(thread_id)
        return unless child
        return unless child.status == 'pending'

        @runtime.transition_child_task(child.child_id, &:start)
      end

      # A request left `claimed`/`running` belongs to a worker that died holding
      # it. `recover` re-enters that exact execution rather than starting a new
      # one, which is what keeps a crash from becoming a second effect.
      def recover(session, thread_id:, occurrence_id:)
        emit("request.recovered", thread: thread_id, request_id: occurrence_id)
        request = session.app.durable_runner.recover(
          thread: thread_id, request_id: occurrence_id, owner_id: owner_id
        )
        notify_milestone(thread_id, "request.recovered", occurrence_id, phase: "recovered")
        observe_cancellation(request, thread_id:)
        settle_schedule_occurrence(session, thread_id:, occurrence_id:, request:)
        settle(session, thread_id:, occurrence_id:, request:)
      end

      # The durable `observed` point of the cancellation timeline (plan 03,
      # work item 4): the runner has consumed the cancel operation, so the
      # stamp lands before settlement. First-write-wins in the store; a
      # projection failure never becomes fatal to the turn that produced it.
      def observe_cancellation(request, thread_id:)
        return unless cancellation_redirect?(request)

        comms_store&.mark_cancellation_observed(thread_id:, now: Time.now.utc)
      rescue StandardError
        nil
      end

      def cancellation_redirect?(request)
        return false unless request.respond_to?(:operation) && request.operation == :redirect

        task = request.respond_to?(:payload) ? request.payload : nil
        task.is_a?(Hash) && task['task'].is_a?(Hash) && task['task']['cancel'] == true
      end

      def comms_store
        return @comms_store if defined?(@comms_store)
        return unless @runtime.respond_to?(:adapter) && @runtime.respond_to?(:checkpoints) &&
                      @runtime.adapter.respond_to?(:bind_comms_store)

        @comms_store = @runtime.adapter.bind_comms_store(@runtime.checkpoints)
      end

      def settle_schedule_occurrence(session, thread_id:, occurrence_id:, request:)
        return unless @runtime.respond_to?(:schedule_occurrence)

        occurrence = @runtime.schedule_occurrence(occurrence_id)
        return unless occurrence

        view = view_of(session, thread_id)
        execution_id = view&.execution_id || request&.execution_id
        return unless execution_id

        if occurrence.state == :enqueued
          @runtime.schedule_store.acknowledge_occurrence(
            occurrence.occurrence_id, execution_id:, fence: occurrence.fence
          )
          occurrence = @runtime.schedule_occurrence(occurrence_id)
        end
        return unless occurrence&.state == :running

        status = scheduled_terminal_status(view, request)
        return unless status

        @runtime.schedule_store.complete_occurrence(
          occurrence.occurrence_id,
          execution_id:,
          status:,
          evidence: {
            'request_id' => occurrence_id,
            'checkpoint_id' => view&.checkpoint_id,
            'execution_id' => execution_id,
            'status' => status.to_s
          }.compact
        )
      rescue Tamoz::Scheduler::SchedulerError, Tamoz::Scheduler::LeaseLostError => error
        emit('schedule.error', reason: error.message)
      end

      def scheduled_terminal_status(view, request)
        if view&.status == :completed
          return :succeeded if view.terminal&.fetch('satisfied', false) == true

          return :failed
        end
        return :failed if view&.status == :failed
        return :unknown if view&.status == :blocked
        # A completed request without its terminal projection is not enough to
        # prove verification. Keep the occurrence non-green until the projection
        # is available rather than treating delivery completion as task success.
        return :unknown if request&.status == :completed
        return :failed if request&.status == :failed

        nil
      end

      # Where the turn ended up, reported against the OCCURRENCE — the queued
      # request an operator asked for — not against whatever internal resume or
      # continue request happened to finish it.
      # A thread with no checkpoint has not started; that is a legitimate state
      # between enqueue and first execution, not an error to propagate.
      def view_of(session, thread_id)
        session.view(thread: thread_id)
      rescue Tamoz::CheckpointConflictError
        nil
      end

      def settle(session, thread_id:, occurrence_id:, request: nil)
        # The budget is checked BEFORE the outcome is interpreted, so a run that
        # spent its ceiling stops as a budget stop rather than being reported as
        # whatever the turn happened to look like when it ran out.
        spent = exhausted_budget(thread_id)
        if spent
          return budget_exhausted(
            {thread_id:, head_request_id: occurrence_id},
            budget: spent.fetch(:budget), detail: spent.fetch(:detail)
          )
        end

        view = view_of(session, thread_id)
        emit_durable_model_calls(session, thread_id:, request_id: request&.request_id || occurrence_id)
        return IDLE unless view

        duration_ms = @runtime.occurrence_age_milliseconds(thread_id)
        settle_child_task(thread_id, view)

        if request && request.status == :failed && view.execution_id != request.execution_id
          return settle_stale_request(thread_id, occurrence_id, request, duration_ms)
        end

        settle_view(view, thread_id, occurrence_id, duration_ms)
      end

      def settle_stale_request(thread_id, occurrence_id, request, duration_ms)
        # A stale claim carries the thread's previous checkpoint, not this
        # occurrence's. Fail it closed so an approval prompt cannot dangle.
        notify_sink(thread_id, "request.failed",
                    'That message could not be started because earlier work in this conversation ' \
                    'never settled. Please send it again.',
                    request_id: occurrence_id)
        close_occurrence(thread_id, occurrence_id)
        unpark(thread_id)
        emit("request.failed",
             thread: thread_id, request_id: occurrence_id,
             duration_ms:,
             reason: failure_reason(request))
        PROGRESSED
      end

      def settle_view(view, thread_id, occurrence_id, duration_ms)
        case view.status
        when :completed
          if cancellation_terminal?(view)
            settle_cancelled_view(view, thread_id, occurrence_id, duration_ms)
          else
            settle_completed_view(view, thread_id, occurrence_id, duration_ms)
          end
        when :failed then settle_failed_view(view, thread_id, occurrence_id, duration_ms)
        when :blocked then settle_blocked_view(view, thread_id, occurrence_id, duration_ms)
        when :paused then settle_paused_view(view, thread_id, occurrence_id, duration_ms)
        else
          notify_milestone(thread_id, "request.running", occurrence_id,
                           phase: committed_phase(view) || "running")
          PROGRESSED
        end
      end

      # The latest engine lifecycle phase in the committed checkpoint state —
      # a durable fact, never a guess about work still ahead.
      def committed_phase(view)
        Array(view.lifecycle_events).last&.fetch("phase", nil)
      end

      # Outbox row BEFORE close (design §11): a crash between the two still
      # leaves the terminal answer deliverable.
      def settle_terminal_delivery(thread_id, kind, occurrence_id, text, phase: nil)
        notify_sink(thread_id, kind, text, request_id: occurrence_id, phase:)
        close_occurrence(thread_id, occurrence_id)
        unpark(thread_id)
      end

      def pending_status_projection(view, occurrence_id)
        SessionStatusProjection.document(view, request_id: occurrence_id, delivery_state: 'pending')
      end

      # A verified completion is "Verified"; a direct chat response completes
      # without proving anything, so its terminal card must not over-claim
      # verification. The phase rides to the sink, which renders the class.
      def completion_verification_phase(view)
        return 'direct_response' if view.terminal&.fetch('reason', nil) == 'direct_response'

        nil
      end

      # The graph checkpoint status of a cancellation terminal is :completed, but
      # its terminal reason is a cancellation, so dispatching on status alone
      # delivered it as request.completed/Verified — contradicting a body that
      # says verification was not satisfied. A cancelled turn is a stop, never a
      # verified completion.
      def cancellation_terminal?(view)
        view.terminal&.fetch('reason', nil) == 'cancelled_by_user'
      end

      def settle_cancelled_view(view, thread_id, occurrence_id, duration_ms)
        settle_terminal_delivery(thread_id, "request.stopped", occurrence_id,
                                 stop_text(view, reason: 'cancelled_by_user'))
        emit("request.stopped",
             thread: thread_id, request_id: occurrence_id, reason: "cancelled_by_user",
             duration_ms:,
             status_projection: pending_status_projection(view, occurrence_id),
             observability: {execution_id: view.execution_id})
        PROGRESSED
      end

      def settle_completed_view(view, thread_id, occurrence_id, duration_ms)
        @monitor.synchronize { @processed += 1 }
        settle_terminal_delivery(thread_id, "request.completed", occurrence_id, completion_text(view),
                                 phase: completion_verification_phase(view))
        emit("request.completed",
             thread: thread_id, request_id: occurrence_id, status: "completed",
             duration_ms:,
             status_projection: pending_status_projection(view, occurrence_id),
             observability: {execution_id: view.execution_id})
        PROGRESSED
      end

      def settle_failed_view(view, thread_id, occurrence_id, duration_ms)
        # Correspondents receive a generic phrase; the detailed reason remains
        # in the worker event stream for operators.
        settle_terminal_delivery(thread_id, "request.failed", occurrence_id, failure_text(view))
        emit("request.failed",
             thread: thread_id, request_id: occurrence_id,
             duration_ms:,
             reason: settled_failure_reason(view),
             status_projection: pending_status_projection(view, occurrence_id),
             observability: {execution_id: view.execution_id})
        PROGRESSED
      end

      def settle_blocked_view(view, thread_id, occurrence_id, duration_ms)
        settle_terminal_delivery(thread_id, "request.blocked", occurrence_id, blocked_text(view))
        emit("request.blocked",
             thread: thread_id,
             request_id: occurrence_id,
             duration_ms:,
             reason: "effect_unknown",
             status_projection: pending_status_projection(view, occurrence_id),
             observability: {execution_id: view.execution_id})
        PROGRESSED
      end

      def settle_paused_view(view, thread_id, occurrence_id, duration_ms)
        reason = pause_reason(view)
        if view.interrupts.empty?
          emit("request.paused",
               thread: thread_id, request_id: occurrence_id, reason: "paused",
               duration_ms:,
               status_projection: pending_status_projection(view, occurrence_id),
               observability: {execution_id: view.execution_id})
        elsif reason == 'clarification_required'
          delivery = notify_sink(thread_id, "request.clarification_request", nil,
                                  request_id: occurrence_id, interrupts: interrupt_facts(view))
          if delivery == :capacity_refused
            emit('worker.error', reason: 'clarification delivery refused: outbox capacity')
            return IDLE
          end
          emit_paused_request(thread_id, occurrence_id, view, reason:)
        else
          notify_milestone(thread_id, "request.waiting", occurrence_id, phase: "waiting")
          notify_sink(thread_id, "request.approval_request", "Approval requested.",
                      request_id: occurrence_id, interrupts: interrupt_facts(view))
          emit_paused_request(thread_id, occurrence_id, view, reason:)
        end
        park({thread_id:, head_request_id: occurrence_id}, view, reason:)
        PARKED
      end

      def clarification_pause?(view)
        view.interrupts.any? do |interrupt|
          interrupt.descriptor&.fetch('kind', nil) == 'clarify'
        end
      end

      def pause_reason(view)
        clarification_pause?(view) ? 'clarification_required' : 'approval_required'
      end

      def settle_child_task(thread_id, view)
        @runtime.settle_child_task(thread_id, view)
      end

      def settle_child_error(thread_id, error)
        child = @runtime.child_task(thread_id)
        return unless child && %w[pending running].include?(child.status)

        receipt = "#{error.class}: #{error.message}".byteslice(0, 1024)
        @runtime.transition_child_task(child.child_id) do |current|
          next current unless %w[pending running].include?(current.status)

          if error.is_a?(Tamoz::EffectUnknownError)
            current.unknown(receipt:)
          else
            current.fail(receipt:)
          end
        end
      rescue StandardError => transition_error
        emit('worker.error', reason: "child settlement failed: #{transition_error.message}")
      end

      def emit_paused_request(thread_id, occurrence_id, view, reason:)
        duration_ms = @runtime.occurrence_age_milliseconds(thread_id)
        emit("request.paused",
             thread: thread_id,
             request_id: occurrence_id,
             duration_ms:,
             reason:,
             interrupts: view.interrupts.map { |interrupt| describe_interrupt(interrupt) },
             status_projection: pending_status_projection(view, occurrence_id),
             observability: {execution_id: view.execution_id})
      end

      # The channel projection: lifecycle events become outbox rows BEFORE the
      # occurrence closes (design §11), so a crash never loses the terminal
      # answer. Nil-safe — an unconfigured worker delivers nothing. A
      # human-answer pause carries the occurrence and its exact interrupt set so
      # the rendered question answers THAT question (ADR-043).
      def notify_sink(thread_id, kind, text, request_id: nil, interrupts: nil, sequence: nil, phase: nil)
        @runtime.delivery_sink&.push(thread_id:, kind:, text:, request_id:, interrupts:,
                                     sequence:, phase:)
      end

      # One lifecycle milestone (plan 03, work item 1): projected from a fact
      # that has ALREADY committed, with the request's short reference and a
      # sequence monotonic within the request. A projection failure is
      # dropped, never fatal to the turn that produced the fact.
      def notify_milestone(thread_id, kind, request_id, phase:)
        return unless request_id

        sequence = @monitor.synchronize do
          @milestone_sequences[request_id] = (@milestone_sequences[request_id] || 0) + 1
        end
        notify_sink(thread_id, kind, nil, request_id:, sequence:, phase:)
      rescue StandardError
        nil
      end

      # What a correspondent receives when a turn completes: the VERIFIED
      # answer, the same text `tamoz show` prints — never the session state
      # that produced it, which is internal detail and unbounded. A completion
      # that verified nothing still owes the channel a terminal message, so it
      # says so plainly rather than delivering an empty one.
      # :reek:UtilityFunction -- a pure function of the view. # -- the message remains one bounded
      # deterministic projection of the terminal state.
      def completion_text(view)
        answer = view.state&.dig(:verification, "answer").to_s
        satisfied = view.terminal&.fetch('satisfied', false)
        if satisfied
          [answer.empty? ? 'Completed.' : answer, TerminalProgress.artifact_line(view)].compact.join("\n")
        elsif view.terminal&.fetch('reason') == 'direct_response'
          [answer, 'Response provided; no task completion was claimed.'].reject(&:empty?).join("\n")
        else
          [answer, TerminalProgress.progress_line(view), TerminalProgress.artifact_line(view),
           'Verification was not satisfied.',
           "Next action: #{TerminalProgress.next_action(view.terminal&.fetch('reason', nil))}"].compact.reject(&:empty?).join("\n")
        end
      end

      def blocked_text(view)
        stop_text(view, reason: 'effect_unknown')
      end

      # rubocop:disable Style/StringConcatenation -- the terminal message is
      # assembled from bounded independent lines.
      def failure_text(view)
        [TerminalProgress.progress_line(view), TerminalProgress.artifact_line(view),
         'Work failed before verified completion.',
         "Next action: #{TerminalProgress.next_action('failed')}"].compact.join("\n") + '.'
      end

      # The reason a settled turn failed, derived from the session state the
      # view carries: the first bounded tool-failure signature, or the terminal
      # reason (e.g. `repair_plan_rejected`). For a plan rejection the first
      # three STRUCTURAL review issues are included — the same bounded
      # disclosure the raised PlanRejectedError path already makes.
      # Semantic/protocol feedback and the reviewer's prose stay hidden: model
      # output is never echoed, but an operator now sees the failure class.
      def settled_failure_reason(view)
        failure = Array(view.state[:observations]).reverse.find { |record| record['failure'] }
        if failure
          record = failure.fetch('failure')
          return "#{record.fetch('error_class')}:#{record.fetch('reason')}"
        end

        terminal = view.state[:terminal_reason]
        return 'failed' unless terminal

        issues = structural_review_issues(view.state)
        issues.empty? ? terminal : "#{terminal}: #{issues.first(3).join('; ')}"
      end

      def structural_review_issues(state)
        review = Array(state[:plan_reviews]).last
        return [] unless review && review['layer'] == 'structural' && review['decision'] == 'revise'

        Array(review['issues'])
      end

      def stop_text(view, reason:, budget: nil)
        [TerminalProgress.progress_line(view), TerminalProgress.artifact_line(view),
         'Work stopped before verified completion.',
         "Next action: #{TerminalProgress.next_action(reason, budget:)}"].compact.join("\n") + '.'
      end
      # rubocop:enable Style/StringConcatenation

      # What a correspondent receives when a turn dies by raising (never by
      # settling): static phrases only. The error's own text stays in the
      # worker's event stream — a plan rejection's reviewer feedback is model
      # output, and model output is never echoed to the channel.
      # :reek:UtilityFunction -- a pure function of the error class.
      def crashed_text(error)
        if error.is_a?(PlanRejectedError)
          'I could not form a plan for that request that passed my own review. ' \
            'Try rephrasing it or adding more detail about what you want done.'
        elsif error.is_a?(Tamoz::CheckpointConflictError)
          'That request stopped safely. Check its status before retrying.'
        else
          'That request failed before it could finish. Please try sending it again.'
        end
      end

      def describe_interrupt(interrupt)
        {
          "kind" => interrupt.respond_to?(:kind) ? interrupt.kind.to_s : nil,
          "task_id" => interrupt.respond_to?(:task_id) ? interrupt.task_id : nil
        }.compact
      end

      # The canonical digest of the interrupt set this view is paused on. The
      # CLI derives the same digest from the same session view when it records
      # a decision, so the two sides agree on the exact question being answered.
      # :reek:UtilityFunction -- a pure function of the view, like the other
      # stateless interrupt helpers in this file.
      def interrupt_digest(view)
        Tamoz::Comms::InterruptDigest.of(interrupt_facts(view))
      end

      # The interrupt set as plain facts. The prompt the channel renders and
      # the digest a decision binds are both derived from THIS, so the deny
      # press can only ever resolve the exact question that was asked.
      # :reek:UtilityFunction -- a pure function of the view.
      def interrupt_facts(view)
        view.interrupts.map do |interrupt|
          {
            task_id: interrupt.task_id,
            call_index: interrupt.call_index,
            descriptor: interrupt.descriptor
          }
        end
      end

      # ------------------------------------------------------------- mode switch

      # The third inbox job (ADR §2.6): apply an operator's mode switch at a
      # durable boundary, BEFORE the request queue can mistake it for a turn.
      # A queued switch always sits behind an open occurrence by inbox
      # ordering, so an in-flight turn is never re-decided — the rebind lands
      # between turns and governs the next decision only.
      def drain_mode_switches
        applied = 0
        @runtime.checkpoints.pending_threads(limit: @batch).each do |entry|
          request = @runtime.checkpoints.fetch_request(
            thread_id: entry.fetch(:thread_id),
            namespace: entry.fetch(:namespace),
            request_id: entry.fetch(:head_request_id)
          )
          next unless request&.operation == :mode_switch && !request.terminal?

          applied += 1 if apply_mode_switch(request)
        end
        applied
      rescue WorkerRuntime::StoreUnavailableError => error
        emit('worker.error', reason: error.message)
        0
      end

      # Claim → rebind → complete, each step fenced or idempotent: the claim is
      # a leased compare-and-set, the rebind is set-semantics whose audit
      # record dedupes on the switch id (the request id), and completion is one
      # fenced transition. A crash anywhere replays to exactly one application.
      def apply_mode_switch(request)
        thread_id = request.thread_id
        profile_id = @runtime.thread_profile(thread_id)
        # Bind before rebinding: a lazy session build stamps the live global
        # rev onto this key, which would silently discard the switch. Go through
        # session_for so the bound profile digest is validated, not a widened
        # on-disk profile.
        @runtime.session_for(thread_id)

        @runtime.checkpoints.open_writer(
          thread_id: thread_id,
          namespace: request.namespace,
          owner_id: owner_id,
          ttl: @runtime.checkpoints.writer_ttl
        ) do |writer|
          claimed = claim_mode_switch(writer, request)
          return false unless claimed

          begin
            @runtime.approval_engine.rebind_session(
              profile: request.payload.fetch('mode'),
              session_id: "profile:#{profile_id || 'default'}",
              switch_id: request.request_id
            )
          rescue Tamoz::Approval::InvalidPolicyError => error
            # An operator typo must not poison the inbox: fail the request
            # terminally under our own lease and report it.
            writer.terminal_fail(request_id: request.request_id,
                                 operation: :mode_switch,
                                 reason: bounded_reason(error))
            emit('worker.error', reason: "mode switch rejected: #{error.message}")
            return true
          end

          writer.complete_request(request_id: request.request_id, execution_id: claimed.execution_id)
          emit('request.mode_switched',
               thread: thread_id,
               request_id: request.request_id,
               mode: request.payload.fetch('mode'))
        end
        true
      rescue StandardError => error
        emit('worker.error', reason: "mode switch #{request.request_id}: #{error.message}")
        false
      end

      def claim_mode_switch(writer, request)
        if request.status == :queued
          candidate = writer.claim_next_request(validator: nil)
          return candidate if candidate&.request_id == request.request_id

          return nil
        end

        # A crash left the switch claimed under an expired lease; recovery
        # takes it over under this pass's fresh fence.
        writer.recover_request(request_id: request.request_id, validator: nil)
      end

      # ----------------------------------------------------------------- parking

      # A parked thread is one whose next move belongs to a human. It is skipped
      # until its head request changes, so a human response delivered by another
      # process un-parks it on the next pass with no signalling between them.
      def park(entry, view, reason: "approval_required")
        meta = {
          signature: [entry.fetch(:head_request_id), view&.status, reason],
          since: Time.now.utc,
          occurrence_id: entry.fetch(:head_request_id)
        }
        @monitor.synchronize { @parked[entry.fetch(:thread_id)] = meta }
        true
      end

      def unpark(thread_id)
        @monitor.synchronize { @parked.delete(thread_id) }
      end

      # A policy with on_timeout: deny does not wait forever for a human: a
      # parked approval whose ask has been pending past ask.timeout_s resolves
      # to a structured denial and the turn continues. Park (:park policy)
      # leaves the decision resolvable by an operator indefinitely.
      # Timeout is judged per LANE by the document that lane is bound to (a
      # mid-session switch may have moved it off the boot policy), and by how
      # long the ASK has been pending — never by how long the occurrence has
      # existed. The occurrence age is only a cheap upper-bound prefilter;
      # apply_timeout_denial re-checks the real ask clock from the decision
      # row before resolving.
      def enforce_ask_deadlines
        now = Time.now.utc
        candidates = parked_deadline_ages(now)
        open_occurrence_deadline_ages(now).each { |thread_id, age| candidates[thread_id] ||= age }

        candidates.each do |thread_id, lower_bound_age_s|
          ask = lane_ask(thread_id)
          next unless ask.fetch(:on_timeout) == :deny
          next unless lower_bound_age_s >= ask.fetch(:timeout_s)

          apply_timeout_denial(thread_id)
        end
      end

      # Parked ages are exact (stamped when the pause was recorded) and win over
      # an occurrence's cheap upper bound; the scan only fills threads with no
      # parked approval.
      def parked_deadline_ages(now)
        @monitor.synchronize do
          @parked.each_with_object({}) do |(thread_id, meta), ages|
            next unless meta[:signature].last == 'approval_required'

            ages[thread_id] = now - meta[:since]
          end
        end
      end

      def open_occurrence_deadline_ages(now)
        @runtime.open_occurrences(limit: 500).each_with_object({}) do |occurrence, ages|
          opened = occurrence[:opened_at]
          next unless opened

          ages[occurrence.fetch(:thread_id)] = now - Time.parse(opened)
        end
      end

      def lane_ask(thread_id)
        engine = @runtime.approval_engine
        key = "profile:#{@runtime.thread_profile(thread_id) || 'default'}"
        document = engine.policy_for(key)
        (@ask_cache ||= {})[[key, document.policy_rev]] ||= document.ask
      end

      def apply_timeout_denial(thread_id)
        occurrence_id = timeout_occurrence_id(thread_id)
        return unless occurrence_id

        session = @runtime.session_for(thread_id)
        # Re-read the view: the ask may have been answered by another channel
        # while parked; only a still-paused approval may time out.
        view = view_of(session, thread_id)
        return unless view && view.status == :paused && !view.interrupts.empty?

        ask = lane_ask(thread_id)
        return unless ask.fetch(:on_timeout) == :deny
        pending_ms = oldest_open_ask_ms(view.interrupts, now_ms: (Time.now.to_f * 1000).to_i)
        return unless pending_ms && pending_ms >= ask.fetch(:timeout_s) * 1000

        resolve_approval_asks(view.interrupts, answer: :deny, scope: nil)
        answers = answers_for(view.interrupts, false)
        conclude_resolution(session,
                            thread_id: thread_id, occurrence_id: occurrence_id, view: view,
                            granted: false, actor: 'policy.timeout', message: 'Denied.',
                            resume_request_id: "timeout-#{occurrence_id}", answers: answers)
      rescue StandardError => error
        emit('worker.error', reason: error.message)
      end

      def timeout_occurrence_id(thread_id)
        meta = @monitor.synchronize { @parked[thread_id] }
        meta&.fetch(:occurrence_id) ||
          @runtime.open_occurrences(limit: 500)
                  .find { |occ| occ.fetch(:thread_id) == thread_id }
                  &.fetch(:occurrence_id)
      end

      # How long the OLDEST open approval ask in this pause has been pending.
      def oldest_open_ask_ms(interrupts, now_ms:)
        interrupts.map(&:descriptor).compact.filter_map do |descriptor|
          next unless descriptor['kind'] == 'approve_tool'

          created = @runtime.approval_engine.decision_log.decision_created_at_ms(
            descriptor.dig('decision', 'id')
          )
          now_ms - created if created
        end.max
      end

      # The terminal error column bounds its reason (512 bytes, no control
      # characters), so a raised claim failure is truncated before it is
      # persisted.
      # :reek:UtilityFunction -- a pure projection of the failure text.
      def bounded_reason(error)
        text = "#{error.class}: #{error.message}"
        text = text.gsub(/[[:cntrl:]]/, ' ')
        text.bytesize <= 512 ? text : text.byteslice(0, 512)
      end

      # The durable reason recorded on a terminal-failed request (the staleness
      # verdict), or a fallback when the row has none.
      # :reek:UtilityFunction -- a pure projection of the request row.
      def failure_reason(request)
        error = request.terminal_error
        return "failed" unless error.is_a?(Hash)

        error.fetch("reason", "failed").to_s
      end

      def parked?(entry)
        @monitor.synchronize do
          meta = @parked[entry.fetch(:thread_id)]
          next false unless meta
          signature = meta.fetch(:signature)

          # A failed claim parks even a :queued entry: without this, the worker
          # would re-claim it every poll and hot-loop (bounded to one attempt
          # per process start, since the park is in-memory).
          signature.first == entry.fetch(:head_request_id) &&
            (entry.fetch(:head_status) != :queued || signature.last == "failed")
        end
      end

      # ------------------------------------------------------------------- idle

      # Sleep the poll interval, but wake the moment the token is cancelled so
      # SIGTERM is not held hostage by a long interval.
      # The remaining time is measured ONCE per pass and then slept. Reading the
      # clock again between the test and the sleep is a race: cross the deadline
      # in that window and the interval is negative, which raises. One pass is
      # unlikely to lose it; a worker idling for hours is not, and the process
      # dies far from the code that caused it.
      def sleep_until_due
        if Tamoz::Cancellation.interruptible_sleep(@poll_interval, token: @cancellation)
          :cancelled
        else
          :due
        end
      end

      def owner_id = @owner_id ||= "worker:#{SecureRandom.uuid}"

      def value_of(result)
        result.respond_to?(:value) ? result.value : result
      end

      def emit(event, **fields)
        observability = fields.delete(:observability) || fields.delete("observability") || {}
        document = {"event" => event, "ts" => Time.now.utc.iso8601}.merge(
          fields.transform_keys(&:to_s)
        )
        emit_observability(event, document, observability:)
        @emitter.call(document)
      end

      def emit_observability(event, document, observability: {})
        name = {
          "worker.started" => "tamoz.worker.started",
          "worker.stopped" => "tamoz.worker.stopped",
          "worker.error" => "tamoz.worker.error",
          "schedule.materialized" => "tamoz.worker.schedule.materialized",
          "schedule.error" => "tamoz.worker.schedule.error"
        }.fetch(event) { event.start_with?("request.") ? "tamoz.worker.request.#{event.delete_prefix("request.")}" : nil }
        return unless name && Tamoz::Observability::Catalog.registered?(name)

        @observability.emit(
          name,
          correlation: observability_correlation(document, observability),
          attributes: observable_attributes(name, document)
        )
      rescue StandardError
        :dropped
      end

      def observability_correlation(document, observability)
        correlation = {}
        correlation[:thread_id] = document["thread"] if document["thread"]
        correlation[:occurrence_id] = document["request_id"] if document["request_id"]
        correlation[:execution_id] = observability[:execution_id] if observability[:execution_id]
        correlation
      end

      def observable_attributes(name, document)
        optional = Tamoz::Observability::Catalog.fetch(name).optional
        optional.keys.filter_map do |key|
          key = key.to_s
          next unless document.key?(key)

          value = document.fetch(key)
          declaration = optional.fetch(key.to_sym)
          if declaration == :low_cardinality && !value.to_s.match?(Tamoz::Observability::SignalCatalog::LOW_CARDINALITY_PATTERN)
            value = "sha256:#{Digest::SHA256.hexdigest(value.to_s)}"
          end
          [key, value]
        end.to_h
      end

      def emit_durable_model_calls(session, thread_id:, request_id:)
        return unless @runtime.respond_to?(:checkpoints) && session.respond_to?(:effect)

        seed_model_effect_keys(thread_id)
        rows = @runtime.checkpoints.effect_census(limit: 10_000).select do |row|
          row.fetch(:thread_id) == thread_id &&
            row.fetch(:status) == :succeeded &&
            row.fetch(:operation).to_s.start_with?("model.generate.")
        end
        rows.each do |row|
          effect_key = row.fetch(:effect_key)
          next unless claim_model_effect(effect_key)

          result = emit_durable_model_call(
            session, thread_id:, request_id:, effect_key:
          )
          release_model_effect(effect_key) if result == :dropped
        end
      rescue StandardError
        :dropped
      end

      def emit_durable_model_call(session, thread_id:, request_id:, effect_key:)
        record = session.effect(thread: thread_id, effect_key:)
        return :dropped unless record && record.status == :succeeded

        attempt = record.attempts.reverse.find { |entry| entry.status == :succeeded }
        return :dropped unless attempt

        model = session.model if session.respond_to?(:model)
        provider = model_identity(model, :provider)
        model_name = model_identity(model, :model_identifier)
        model_call = Tamoz::Observability::ModelCall.new(
          producer: @observability, provider:, model: model_name
        )
        model_call.emit(
          correlation: {
            thread_id:, execution_id: record.execution_id, request_id:,
            task_id: record.task_id, effect_key:
          },
          started_at_ms: attempt.started_at_ms,
          ended_at_ms: attempt.completed_at_ms,
          usage: model_usage(attempt.result),
          request_digest: record.request_digest
        )
      rescue StandardError
        :dropped
      end

      def claim_model_effect(effect_key)
        @model_effect_monitor.synchronize do
          next false if @model_effect_keys.include?(effect_key)

          @model_effect_keys.add(effect_key)
          true
        end
      end

      def seed_model_effect_keys(thread_id)
        return unless @runtime.respond_to?(:path)

        keys = Tamoz::Observability::Recorder::Journal.read(
          @runtime.path, role: "worker", thread_id:, kind: "event"
        ).filter_map do |document|
          document.dig("correlation", "effect_key") if document["name"] == "tamoz.model.call"
        end
        @model_effect_monitor.synchronize { @model_effect_keys.merge(keys) }
      rescue StandardError
        :dropped
      end

      def release_model_effect(effect_key)
        @model_effect_monitor.synchronize { @model_effect_keys.delete(effect_key) }
      end

      def model_identity(model, method)
        return "unknown" unless model

        value = model.respond_to?(method) ? model.public_send(method) : model.class.name
        sanitized = value.to_s.gsub(/[^a-zA-Z0-9_.:-]/, "_")[0, 128]
        sanitized.empty? ? "unknown" : sanitized
      end

      def model_usage(result)
        raw = result.is_a?(Hash) && (result["usage"] || result[:usage])
        return unless raw.is_a?(Hash)

        Tamoz::Observability::Usage.new(
          input_tokens: usage_value(raw, "input_tokens"),
          output_tokens: usage_value(raw, "output_tokens"),
          cache_read_tokens: usage_value(raw, "cache_read_tokens"),
          cache_write_tokens: usage_value(raw, "cache_write_tokens")
        )
      rescue Tamoz::Observability::ValidationError
        nil
      end

      def usage_value(usage, key)
        value = usage[key] || usage[key.to_sym]
        value.is_a?(Numeric) ? value.to_i : nil
      end
    end
  end
end
