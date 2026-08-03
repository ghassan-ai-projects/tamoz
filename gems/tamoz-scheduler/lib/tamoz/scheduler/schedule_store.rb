# frozen_string_literal: true

module Tamoz
  module Scheduler
    # P13-A (plan §4, SCHEDULER_DESIGN §11) — the structural ScheduleStore
    # contract. `tamoz-scheduler` depends only on this; `tamoz-sqlite` is the
    # first conforming adapter. Every method is part of the versioned contract,
    # so a conforming adapter is interchangeable.
    #
    # The atomicity seam (C1/DC-4): `materialize_due` is the SOLE public
    # claim/create/enqueue operation and MUST complete claim → create occurrence
    # → enqueue its request in ONE durable transaction. Separate
    # `claim_due`/`enqueue_occurrence` calls cannot promise one transaction and
    # are not conforming. A crash at any point leaves old-or-complete-new state;
    # a repeated delivery re-runs the same transaction and the shared enqueue
    # primitive dedups on the deterministic request id.
    module ScheduleStore
      CONTRACT_VERSION = 1

      # Insert or update a schedule. `expected_revision` is the CAS guard: the
      # write succeeds only when the stored revision matches; a concurrent edit
      # raises `StoreConflictError` and the caller re-reads.
      #
      # @return [Schedule] the stored schedule (new revision)
      def put_schedule(schedule, expected_revision:)
        raise NotImplementedError
      end

      # Pause a schedule (prevents future claims; running occurrences are
      # untouched). CAS on `expected_revision`.
      def disable_schedule(id, expected_revision:, reason:)
        raise NotImplementedError
      end

      # The atomic due scan. Claims every occurrence whose nominal instant (or
      # `not_before` after jitter) has passed, creates the occurrence if absent,
      # derives the deterministic request id, and enqueues the request into the
      # ordinary request inbox — all in ONE transaction under `owner`/`lease_for`.
      #
      # @param request_template [Hash] prevalidated, bounded, provider-free;
      #   its only substitutions are deterministic occurrence identity fields.
      # @return [Array<Occurrence>] occurrences whose durable requests committed
      def materialize_due(now:, owner:, lease_for:, limit:, request_template:)
        raise NotImplementedError
      end

      # Extend the lease on a claimed occurrence. Stale fences fail closed.
      def renew_occurrence_lease(id, fence:, lease_for:)
        raise NotImplementedError
      end

      # Record terminal delivery/execution state for an occurrence. Delivery
      # and execution have DISTINCT statuses: `enqueued` is never reported as
      # execution success (hard zero: no false green).
      def complete_occurrence(id, execution_id:, status:, evidence:)
        raise NotImplementedError
      end

      # Paginated occurrence history for a schedule.
      def list_occurrences(schedule_id:, cursor: nil, limit: 100)
        raise NotImplementedError
      end
    end
  end
end
