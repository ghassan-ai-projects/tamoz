# frozen_string_literal: true

module Tamoz
  module Scheduler
    # What happens to due occurrences: which missed instants run, whether an overlapping one runs, and its jitter.
    class OccurrencePolicy
      def initialize(schedule)
        @schedule = schedule
      end

      # P13-B (design §6) — apply the misfire policy to a window of due
      # instants. A misfire is an occurrence whose nominal time passed while no
      # eligible scheduler delivered it. The policy decides what `materialize`
      # enqueues and what it records as `skipped`; there is never unbounded
      # catch-up (the window itself is bounded by the scan's `limit`).
      #
      # - :skip      — deliver only the latest instant; older ones are skipped.
      # - :latest    — coalesce the whole missed window into the latest instant
      #                (default for recurring).
      # - :replay    — deliver oldest-first up to `misfire_limit`; older ones
      #                are skipped.
      # - :fire_once — one recovery instant for the missed window (default for
      #                one-shots); older ones are skipped.
      def misfire_selection(due_instants)
        return { materialize: [], skipped: [] } if due_instants.empty?

        case misfire_policy
        when :skip, :latest, :fire_once
          # The three policies coincide today by construction: the latest
          # instant carries the work, older dues get their durable skip
          # reason (design §6).
          { materialize: [due_instants.last], skipped: due_instants[0...-1] }
        when :replay
          limit = [misfire_limit, 1].max
          # Oldest-first up to the limit; later ones are skipped.
          { materialize: due_instants.first(limit), skipped: due_instants[limit..] || [] }
        end
      end

      # P13-B (design §7) — the overlap decision given the durable occurrence
      # state. `non_terminal` counts occurrences still in
      # claimed/enqueued/running (in-flight for THIS schedule, never a
      # process-local mutex); `pending` counts those enqueued but not yet
      # running.
      #
      # - :forbid     — any in-flight occurrence skips the new one (default).
      # - :queue_one  — one bounded pending occurrence; a later one coalesces
      #                 into it.
      # - :allow      — run concurrently up to `max_concurrency`.
      def overlap_decision(non_terminal:, pending:)
        case overlap_policy
        when :forbid
          non_terminal.positive? ? :skip : :materialize
        when :queue_one
          pending.positive? ? :coalesce : :materialize
        when :allow
          non_terminal >= max_concurrency ? :skip : :materialize
        end
      end

      # Deterministic jitter: a stable offset in [0, jitter_window) derived from
      # the occurrence identity. Same occurrence → same offset on every call and
      # every process; changes `not_before`, never the identity or nominal
      # instant (design §5).
      def jitter_for(occurrence_id)
        return 0 if jitter_window.nil? || jitter_window.zero?

        digest = Digest::SHA256.hexdigest(occurrence_id)
        (digest.to_i(16) % jitter_window)
      end

      private

      def misfire_policy = @schedule.misfire_policy
      def misfire_limit = @schedule.misfire_limit
      def overlap_policy = @schedule.overlap_policy
      def max_concurrency = @schedule.max_concurrency
      def jitter_window = @schedule.jitter_window
    end

    private_constant :OccurrencePolicy
  end
end
