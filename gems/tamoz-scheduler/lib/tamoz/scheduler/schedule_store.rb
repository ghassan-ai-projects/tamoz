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
      # v2: materialize_due declares current_grant/include_provenance and the
      # lifecycle-symmetric enable_schedule is part of the contract (previously
      # SQLite-only extensions its callers depended on).
      CONTRACT_VERSION = 2

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

      # Resume a paused schedule — the lifecycle-symmetric partner of
      # `disable_schedule`. Enabling is lifecycle state, not definition, so it
      # has its own path rather than a re-`put_schedule` (an edit must not
      # silently un-pause). CAS on `expected_revision`.
      def enable_schedule(id, expected_revision:)
        raise NotImplementedError
      end

      # The atomic due scan. Claims every occurrence whose nominal instant (or
      # `not_before` after jitter) has passed, creates the occurrence if absent,
      # derives the deterministic request id, and enqueues the request into the
      # ordinary request inbox — all in ONE transaction under `owner`/`lease_for`.
      #
      # @param request_template [Hash] prevalidated, bounded, provider-free;
      #   its only substitutions are deterministic occurrence identity fields.
      # @param current_grant the operator policy AT the enforcement point
      #   (invariant 40). The schedule's stored maximum grant is intersected
      #   against it; `nil` fails closed (empty policy — nothing survives).
      # @param include_provenance [Boolean] whether the enqueued request payload
      #   carries the schedule/occurrence identifiers alongside the template. A
      #   consumer whose payload is a closed schema (the agent session) passes
      #   false; the identifiers stay queryable on the occurrence row regardless.
      # @return [Array<Occurrence>] occurrences whose durable requests committed
      def materialize_due(now:, owner:, lease_for:, limit:, request_template:,
                          current_grant:, include_provenance: true)
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
