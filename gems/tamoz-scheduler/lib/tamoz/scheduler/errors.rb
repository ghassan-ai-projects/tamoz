# frozen_string_literal: true

module Tamoz
  module Scheduler
    # Base error for the scheduler package. Typed failures, never the poller
    # crashing: adapter-thrown problems map onto the subclasses (plan §11/C5).
    class SchedulerError < StandardError
      CATEGORY = "scheduler"
      RETRYABLE = false
    end

    # A store CAS conflict (schedule edit race, stale fencing token, or a
    # duplicate enqueue with byte-different payload). The poller re-polls.
    class StoreConflictError < SchedulerError
      CATEGORY = "scheduler_store_conflict"
    end

    # The occurrence lease was lost or the schedule was tombstoned; the claim
    # fails closed and the poller reclaims with a higher fence or moves on.
    class LeaseLostError < SchedulerError
      CATEGORY = "scheduler_lease_lost"
    end

    # Misfire policy reached its limit: the occurrence is recorded as
    # `skipped(reason: limit)` and the NEXT future occurrence continues.
    class MisfireLimitReachedError < SchedulerError
      CATEGORY = "scheduler_misfire_limit"
    end

    # The wall clock jumped backward far enough to be detected. Identity +
    # durable uniqueness already prevent a duplicate occurrence; the poller
    # recomputes from durable UTC time.
    class ClockRollbackError < SchedulerError
      CATEGORY = "scheduler_clock_rollback"
    end
  end
end
