# frozen_string_literal: true

require "digest"

module Tamoz
  module Scheduler
    # P13-D (SCHEDULER_DESIGN §3) — the validated Schedule value.
    #
    # v1 ships the `at` and `interval` kinds only (plan §12 deferral, Round 24):
    # `at` is one nominal UTC instant, `interval` is a fixed elapsed-time cadence
    # from an explicit anchor. Both are pure UTC arithmetic — no `fugit`, no
    # civil-time surface, so invariants 38–40 are non-vacuous for the shipped
    # kinds. `cron` (IANA + DST) is a recorded deferral with entry conditions.
    #
    # The value is IMMUTABLE and content-addressed: `definition_digest` binds
    # every field, and editing creates a new revision (the store CASes on
    # `expected_revision`). Payload and policy artifacts referenced by digest
    # are immutable by contract — a revision never mutates a definition an
    # occurrence already used.
    Schedule = Data.define(
      :id, :revision, :owner, :enabled,
      :kind,                    # :at | :interval
      :expression,              # at: ISO-8601 UTC instant; interval: duration seconds
      :start_at,                # UTC epoch seconds, inclusive
      :end_at,                  # UTC epoch seconds, inclusive (nil = open)
      :misfire_policy,          # :skip | :latest | :replay | :fire_once
      :misfire_limit,
      :overlap_policy,          # :forbid | :queue_one | :allow
      :max_concurrency,
      :jitter_window,           # seconds; deterministic jitter from occurrence id
      :payload_ref,             # content-addressed payload reference (digest string)
      :thread_policy,           # how the occurrence maps to a thread id
      :capability_grant,        # stored maximum grant (P13-C intersects with current)
      :behavior_version,
      :approval_profile,        # named approval profile occurrences run under
      :delivery_policy,
      :budgets,
      :created_by,
      :created_at,              # UTC epoch seconds
      :definition_digest
    ) do
      KINDS = %i[at interval].freeze
      MISFIRE_POLICIES = %i[skip latest replay fire_once].freeze
      OVERLAP_POLICIES = %i[forbid queue_one allow].freeze
      DIGEST_DOMAIN = "tamoz.scheduler.schedule.v1\n"
      MAX_BUDGET_MAGNITUDE = 1_000_000
      DEFAULT_APPROVAL_PROFILE = "implement"

      def initialize(
        id:, revision: 1, owner:, enabled: true,
        kind:, expression:,
        start_at: nil, end_at: nil,
        misfire_policy: :latest, misfire_limit: 1,
        overlap_policy: :forbid, max_concurrency: 1,
        jitter_window: 0, payload_ref:, thread_policy:,
        capability_grant:, behavior_version:,
        approval_profile: DEFAULT_APPROVAL_PROFILE, delivery_policy:, budgets:,
        created_by:, created_at:,
        definition_digest: nil
      )
        @validated = ScheduleValidator.new(
          id:, revision:, owner:, enabled:, kind:, expression:,
          start_at:, end_at:, misfire_policy:, misfire_limit:,
          overlap_policy:, max_concurrency:, jitter_window:,
          payload_ref:, thread_policy:, capability_grant:,
          behavior_version:, approval_profile:, delivery_policy:,
          budgets:, created_by:, created_at:
        ).validate!
        @digest = definition_digest || compute_digest(@validated)
        super(**@validated, definition_digest: @digest)
      end

      # The digest over the canonical DEFINITION. `revision`, `enabled`, and
      # `definition_digest` are excluded: revision is store-assigned lifecycle
      # state (CAS moves it; a superseded copy of identical content is still
      # the same definition), `enabled` toggles via the separate
      # disable/enable path, and the digest cannot bind itself. A revision
      # differs from its parent only when the definition differs.
      def compute_digest(fields)
        definition = fields.reject do |key, _value|
          %i[revision enabled definition_digest].include?(key)
        end
        Tamoz::Core.digest(DIGEST_DOMAIN, definition)
      end
      private :compute_digest

      # The next nominal fire instant at/after `now` (UTC epoch seconds).
      # Returns nil when the schedule is done (end_at passed, one-shot fired).
      def next_fire_at(now)
        FireCalendar.new(self).next_fire_at(now)
      end

      # The due occurrence instants at/after `anchor` up to and including `now`
      # (UTC epoch seconds), oldest first, at most `limit` (1 for `at`).
      # `next_fire_at` answers "when does it fire next" for the poller's
      # horizon; `due_occurrences` is what `materialize_due` claims, including
      # catch-up after a pause or a crash. Misfire policy decides how many
      # missed occurrences materialize (see plan §4/B).
      def due_occurrences(now:, anchor: nil, limit: 10)
        FireCalendar.new(self).due_occurrences(now:, anchor:, limit:)
      end

      def misfire_selection(due_instants)
        OccurrencePolicy.new(self).misfire_selection(due_instants)
      end

      def overlap_decision(non_terminal:, pending:)
        OccurrencePolicy.new(self).overlap_decision(non_terminal:, pending:)
      end

      def jitter_for(occurrence_id)
        OccurrencePolicy.new(self).jitter_for(occurrence_id)
      end

      # Parse the canonical `at` expression to a UTC epoch second.
      #
      # This is the only place the expression becomes a time, so it is also the
      # only place that can tell a real instant from one that merely matches the
      # shape. `Time.utc` alone is not that check: it raises for month 13, but
      # it rolls 2024-02-30 forward to March 1 — a schedule for a date that does
      # not exist would fire on a different day, silently. Both are the same
      # operator mistake and both get the same typed answer, raised at
      # validation time (`validate_times!` calls this) rather than at poll time,
      # because the poller's contract is typed failures, never a crash.
      # :reek:TooManyStatements -- parse, calendar round-trip, and the one typed
      # failure are the whole method; splitting them would put the rollover
      # check somewhere other than the only place that knows the parsed fields.
      def self.at_instant(expression)
        fields = [[0, 4], [5, 2], [8, 2], [11, 2], [14, 2], [17, 2]]
                 .map { |offset, length| expression[offset, length].to_i }
        instant = Time.utc(*fields)
        return instant.to_i if [instant.year, instant.month, instant.day] == fields.first(3)

        # A rolled-over date IS an out-of-range argument; Ruby just does not
        # say so for the day field, so both failures answer through one clause.
        raise ArgumentError, "the date does not exist"
      rescue ArgumentError
        raise Tamoz::ConfigurationError,
              "at expression #{expression.inspect} is not a real UTC instant"
      end

      def to_h
        members.to_h { |member| [member.to_s, wire_value(member)] }
      end

      private

      def wire_value(member)
        value = public_send(member)
        %i[kind misfire_policy overlap_policy].include?(member) ? value.to_s : value
      end
    end
  end
end
