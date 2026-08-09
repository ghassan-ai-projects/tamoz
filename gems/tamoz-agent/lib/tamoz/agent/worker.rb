# frozen_string_literal: true

require "json"
require "securerandom"
require "set"

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
        cancellation: nil
      )
        @runtime = runtime
        @session_builder = session_builder
        @emitter = emitter
        @once = once
        @concurrency = Integer(concurrency).clamp(1, 32)
        @poll_interval = Float(poll_interval)
        @batch = Integer(batch)
        @cancellation = cancellation || Tamoz::CancellationToken.new
        @processed = 0
        # Threads waiting on a human. Keyed by thread so a parked thread neither
        # spins the loop nor blocks its neighbours; the signature lets an arriving
        # approval un-park it without the worker having to be told.
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
        emit("worker.stopped",
             reason: reason || "error",
             processed: @processed,
             parked: @parked.size)
      end

      # One pass: turn due schedules into queued requests, then advance whatever
      # is queued. Returns whether anything moved, which is the only input to the
      # idle decision.
      def poll_once
        materialized = materialize_due_schedules
        advanced = advance_pending_threads
        (materialized + advanced).positive?
      end

      private

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
        actionable = begin
          work_list.reject { |entry| parked?(entry) }
        rescue WorkerRuntime::StoreUnavailableError => error
          # The work list could not be read. That is reported and retried on the
          # next poll — it is NOT an empty inbox, and the difference has to be
          # visible or a sick store looks exactly like a quiet one.
          emit("worker.error", reason: error.message)
          []
        end
        return 0 if actionable.empty?

        pool = Tamoz::Pool.for(
          @concurrency > 1 ? :threads : :inline,
          size: @concurrency,
          max_tasks: @batch,
          cancellation: @cancellation
        )
        results = pool.map(actionable) { |entry| advance_thread(entry) }
        results.count { |result| value_of(result) == PROGRESSED }
      end

      # Where there is work to do.
      #
      # The inbox is only half the answer. A turn that stopped to ask a human
      # COMPLETED its request — the request ran; it is the session that is paused
      # — so an unfinished occurrence can leave the inbox entirely. The durable
      # open-occurrence records are the other half, and they survive a restart,
      # which an in-memory set would not.
      def work_list
        queued = @runtime.checkpoints.pending_threads(limit: @batch)
        seen = queued.map { |entry| entry.fetch(:thread_id) }.to_set
        open = @runtime.open_occurrences(limit: @batch).reject do |record|
          seen.include?(record.fetch(:thread_id))
        end
        queued + open.map do |record|
          {
            thread_id: record.fetch(:thread_id),
            namespace: [],
            head_request_id: record.fetch(:occurrence_id),
            head_status: :open,
            enqueue_sequence: -1
          }
        end
      end

      # Everything that can go wrong with one thread is contained to that thread.
      # A thread that raises is recorded and left alone; it must never take the
      # worker down or stall its neighbours.
      def advance_thread(entry)
        thread_id = entry.fetch(:thread_id)
        occurrence_id = entry.fetch(:head_request_id)
        session = @session_builder.call(thread_id)
        return IDLE unless session

        case entry.fetch(:head_status)
        when :queued
          # A queued request has no checkpoint yet — there is nothing to view and
          # nothing to recover. Run it.
          claim_and_run(session, thread_id:, occurrence_id:)
        when :claimed, :running, :redirecting, :open
          # Non-terminal with a checkpoint behind it: either a human owes this
          # thread an answer, or a worker died holding it. The VIEW decides which,
          # because the request status alone cannot tell those two apart.
          view = view_of(session, thread_id)
          if view && view.status == :paused && !view.interrupts.empty?
            # A human may have answered since the last pass. If they have, the
            # SAME occurrence continues; if they have not, it stays parked.
            decision = @runtime.decision_for(thread_id, occurrence_id)
            return park(entry, view) && PARKED if decision.nil?

            return apply_decision(session, thread_id:, occurrence_id:, view:, granted: decision)
          end

          # An open occurrence with nothing in the inbox and no interrupt is a
          # thread that finished while this worker was not looking; settle it so
          # its record closes rather than being polled forever.
          return settle(session, thread_id:, occurrence_id:) if entry.fetch(:head_status) == :open

          recover(session, thread_id:, occurrence_id:)
        else
          IDLE
        end
      rescue Tamoz::RecursionLimitError => error
        # The graph refused to take another super-step because the profile's
        # `steps` budget is spent. This is a STOP, not a failure: the work was
        # well-formed and the ceiling did its job, so it is reported as its own
        # typed event and recorded durably for `tamoz status`.
        budget_exhausted(entry, budget: "steps", detail: error.message)
      rescue StandardError => error
        emit("request.failed",
             thread: entry.fetch(:thread_id),
             request_id: entry.fetch(:head_request_id),
             reason: "#{error.class}: #{error.message}")
        park(entry, nil, reason: "failed")
        PARKED
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
      def budget_exhausted(entry, budget:, detail:)
        thread_id = entry.fetch(:thread_id)
        occurrence_id = entry.fetch(:head_request_id)
        @runtime.record_budget_exhaustion(thread_id, occurrence_id, budget:, detail:)
        # A budget stop is TERMINAL for the occurrence, so the record is closed.
        # Parking would only be in-memory: the next worker process would have an
        # empty park map, re-examine the same occurrence and stop it again, and
        # the operator would collect one stop event per poll forever. Raising the
        # ceiling and re-queueing is the deliberate way to continue, which is the
        # right amount of friction for work that already spent its budget.
        @runtime.close_occurrence(thread_id)
        unpark(thread_id)
        emit("request.stopped",
             thread: thread_id,
             request_id: occurrence_id,
             reason: "budget_exhausted",
             budget:,
             detail:)
        PROGRESSED
      end

      # Deliver a recorded human decision to the paused turn.
      #
      # The answers are built from the interrupts the session is ACTUALLY waiting
      # on, and every one of them carries the same recorded decision. The worker
      # supplies no value of its own: it is a courier, not a decision-maker.
      def apply_decision(session, thread_id:, occurrence_id:, view:, granted:)
        answers = {}
        view.interrupts.each do |interrupt|
          answers[interrupt.task_id] ||= {}
          answers[interrupt.task_id][interrupt.call_index] = answer_for(interrupt, granted)
        end

        emit("request.#{granted ? "approved" : "denied"}",
             thread: thread_id, request_id: occurrence_id, actor: "human")
        unpark(thread_id)
        session.resume(answers, thread: thread_id, request_id: SecureRandom.uuid,
                                owner_id: owner_id)
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

      def claim_and_run(session, thread_id:, occurrence_id:)
        emit("request.claimed", thread: thread_id, request_id: occurrence_id)
        # Durable BEFORE execution: a crash between here and the first checkpoint
        # must still leave a record that this occurrence was started.
        @runtime.open_occurrence(thread_id, occurrence_id)
        session.app.durable_runner.run_next(thread: thread_id, owner_id: owner_id)
        settle(session, thread_id:, occurrence_id:)
      end

      # A request left `claimed`/`running` belongs to a worker that died holding
      # it. `recover` re-enters that exact execution rather than starting a new
      # one, which is what keeps a crash from becoming a second effect.
      def recover(session, thread_id:, occurrence_id:)
        emit("request.recovered", thread: thread_id, request_id: occurrence_id)
        session.app.durable_runner.recover(
          thread: thread_id, request_id: occurrence_id, owner_id: owner_id
        )
        settle(session, thread_id:, occurrence_id:)
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

      def settle(session, thread_id:, occurrence_id:)
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
        return IDLE unless view

        case view.status
        when :completed
          @monitor.synchronize { @processed += 1 }
          @runtime.close_occurrence(thread_id)
          unpark(thread_id)
          emit("request.completed",
               thread: thread_id, request_id: occurrence_id, status: "completed")
          PROGRESSED
        when :failed
          @runtime.close_occurrence(thread_id)
          unpark(thread_id)
          emit("request.failed",
               thread: thread_id, request_id: occurrence_id,
               reason: view.respond_to?(:error) ? view.error.to_s : "failed")
          PROGRESSED
        when :paused
          if view.interrupts.empty?
            emit("request.paused",
                 thread: thread_id, request_id: occurrence_id, reason: "paused")
          else
            emit_approval_request(thread_id, occurrence_id, view)
          end
          park({thread_id:, head_request_id: occurrence_id}, view)
          PARKED
        else
          PROGRESSED
        end
      end

      def emit_approval_request(thread_id, occurrence_id, view)
        emit("request.paused",
             thread: thread_id,
             request_id: occurrence_id,
             reason: "approval_required",
             interrupts: view.interrupts.map { |interrupt| describe_interrupt(interrupt) })
      end

      def describe_interrupt(interrupt)
        {
          "kind" => interrupt.respond_to?(:kind) ? interrupt.kind.to_s : nil,
          "task_id" => interrupt.respond_to?(:task_id) ? interrupt.task_id : nil
        }.compact
      end

      # ----------------------------------------------------------------- parking

      # A parked thread is one whose next move belongs to a human. It is skipped
      # until its head request changes, so an approval delivered by another
      # process un-parks it on the next pass with no signalling between them.
      def park(entry, view, reason: "approval_required")
        signature = [entry.fetch(:head_request_id), view&.status, reason]
        @monitor.synchronize { @parked[entry.fetch(:thread_id)] = signature }
        true
      end

      def unpark(thread_id)
        @monitor.synchronize { @parked.delete(thread_id) }
      end

      def parked?(entry)
        @monitor.synchronize do
          signature = @parked[entry.fetch(:thread_id)]
          next false unless signature

          signature.first == entry.fetch(:head_request_id) &&
            entry.fetch(:head_status) != :queued
        end
      end

      # ------------------------------------------------------------------- idle

      # Sleep the poll interval, but wake the moment the token is cancelled so
      # SIGTERM is not held hostage by a long interval.
      def sleep_until_due
        deadline = Tamoz::Clock.monotonic.now + @poll_interval
        while Tamoz::Clock.monotonic.now < deadline
          return :cancelled if stopping?

          sleep([0.05, deadline - Tamoz::Clock.monotonic.now].min)
        end
        :due
      end

      def owner_id = @owner_id ||= "worker:#{SecureRandom.uuid}"

      def value_of(result)
        result.respond_to?(:value) ? result.value : result
      end

      def emit(event, **fields)
        @emitter.call({"event" => event, "ts" => Time.now.utc.iso8601}.merge(
          fields.transform_keys(&:to_s)
        ))
      end
    end
  end
end
