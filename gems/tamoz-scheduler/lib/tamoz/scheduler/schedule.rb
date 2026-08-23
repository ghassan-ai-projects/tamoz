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
        @validated = validate!(
          id:, revision:, owner:, enabled:, kind:, expression:,
          start_at:, end_at:, misfire_policy:, misfire_limit:,
          overlap_policy:, max_concurrency:, jitter_window:,
          payload_ref:, thread_policy:, capability_grant:,
          behavior_version:, approval_profile:, delivery_policy:,
          budgets:, created_by:, created_at:
        )
        @digest = definition_digest || compute_digest(@validated)
        super(
          id: @validated.fetch(:id), revision: @validated.fetch(:revision),
          owner: @validated.fetch(:owner), enabled: @validated.fetch(:enabled),
          kind: @validated.fetch(:kind), expression: @validated.fetch(:expression),
          start_at: @validated.fetch(:start_at), end_at: @validated.fetch(:end_at),
          misfire_policy: @validated.fetch(:misfire_policy),
          misfire_limit: @validated.fetch(:misfire_limit),
          overlap_policy: @validated.fetch(:overlap_policy),
          max_concurrency: @validated.fetch(:max_concurrency),
          jitter_window: @validated.fetch(:jitter_window),
          payload_ref: @validated.fetch(:payload_ref),
          thread_policy: @validated.fetch(:thread_policy),
          capability_grant: @validated.fetch(:capability_grant),
          behavior_version: @validated.fetch(:behavior_version),
          approval_profile: @validated.fetch(:approval_profile),
          delivery_policy: @validated.fetch(:delivery_policy),
          budgets: @validated.fetch(:budgets),
          created_by: @validated.fetch(:created_by),
          created_at: @validated.fetch(:created_at),
          definition_digest: @digest
        )
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
        return nil unless enabled
        return nil if end_at && now > end_at

        case kind
        when :at
          instant = self.class.at_instant(expression)
          return nil if instant <= now
          return nil if start_at && instant < start_at
          return nil if end_at && instant > end_at

          instant
        when :interval
          duration = expression.to_i
          anchor = start_at || created_at
          if end_at && anchor > end_at
            # The anchor is past the horizon: nothing can fire.
            return nil
          end

          if now < anchor
            # Before the anchor: the first occurrence is at the anchor.
            return nil if end_at && anchor > end_at

            anchor
          else
            elapsed = now - anchor
            ordinal = (elapsed / duration).floor
            candidate = anchor + (ordinal * duration)
            candidate > now ? candidate : candidate + duration
          end
        end
      end

      # The due occurrence instants at/after `anchor` up to and including `now`
      # (UTC epoch seconds), oldest first, at most `limit` (1 for `at`).
      # `next_fire_at` answers "when does it fire next" for the poller's
      # horizon; `due_occurrences` is what `materialize_due` claims, including
      # catch-up after a pause or a crash. Misfire policy decides how many
      # missed occurrences materialize (see plan §4/B).
      def due_occurrences(now:, anchor: nil, limit: 10)
        return [] unless enabled
        return [] if end_at && now > end_at

        case kind
        when :at
          instant = self.class.at_instant(expression)
          return [] if instant > now
          return [] if start_at && instant < start_at
          return [] if end_at && instant > end_at

          [instant]
        when :interval
          duration = expression.to_i
          start = anchor || start_at || created_at
          return [] if end_at && start > end_at
          return [] if start > now

          count = ((now - start) / duration) + 1
          (0...[count, limit].min).map { |ordinal| start + (ordinal * duration) }
        end
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
        return {materialize: [], skipped: []} if due_instants.empty?

        case misfire_policy
        when :skip
          {materialize: [due_instants.last], skipped: due_instants[0...-1]}
        when :latest
          # Coalesce the covered range: every older due instant is recorded
          # with a durable reason (design §6: "every due occurrence has
          # exactly one durable reason"), the latest carries the work.
          {materialize: [due_instants.last], skipped: due_instants[0...-1]}
        when :replay
          limit = [misfire_limit, 1].max
          # Oldest-first up to the limit; later ones are skipped.
          {materialize: due_instants.first(limit), skipped: due_instants[limit..] || []}
        when :fire_once
          {materialize: [due_instants.last], skipped: due_instants[0...-1]}
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
        {
          "id" => id, "revision" => revision, "owner" => owner,
          "enabled" => enabled, "kind" => kind.to_s,
          "expression" => expression, "start_at" => start_at, "end_at" => end_at,
          "misfire_policy" => misfire_policy.to_s, "misfire_limit" => misfire_limit,
          "overlap_policy" => overlap_policy.to_s, "max_concurrency" => max_concurrency,
          "jitter_window" => jitter_window, "payload_ref" => payload_ref,
          "thread_policy" => thread_policy,
          "capability_grant" => capability_grant,
          "behavior_version" => behavior_version,
          "approval_profile" => approval_profile,
          "delivery_policy" => delivery_policy,
          "budgets" => budgets, "created_by" => created_by,
          "created_at" => created_at, "definition_digest" => definition_digest
        }
      end

      private

      def validate!(
        id:, revision:, owner:, enabled:, kind:, expression:,
        start_at:, end_at:, misfire_policy:, misfire_limit:,
        overlap_policy:, max_concurrency:, jitter_window:,
        payload_ref:, thread_policy:, capability_grant:,
        behavior_version:, approval_profile:, delivery_policy:,
        budgets:, created_by:, created_at:
      )
        # An omitted profile is the default one, not an error, so a schedule
        # that says nothing runs under the same policy as ordinary work.
        approval_profile = DEFAULT_APPROVAL_PROFILE if approval_profile.nil?
        validate_id!(id)
        validate_revision!(revision)
        validate_string!(owner, "owner")
        validate_kind!(kind, expression)
        validate_times!(kind, expression, start_at, end_at)
        validate_enum!(misfire_policy, MISFIRE_POLICIES, "misfire_policy")
        validate_limit!(misfire_limit, "misfire_limit")
        validate_enum!(overlap_policy, OVERLAP_POLICIES, "overlap_policy")
        validate_limit!(max_concurrency, "max_concurrency")
        validate_limit!(jitter_window, "jitter_window")
        validate_digest!(payload_ref, "payload_ref")
        validate_string!(thread_policy, "thread_policy")
        validate_hash!(capability_grant, "capability_grant")
        validate_string!(behavior_version, "behavior_version")
        validate_string!(approval_profile, "approval_profile")
        validate_hash!(delivery_policy, "delivery_policy")
        validate_budgets!(budgets)
        validate_string!(created_by, "created_by")
        validate_time!(created_at, "created_at")

        {
          id:, revision:, owner:, enabled:, kind:, expression:,
          start_at:, end_at:, misfire_policy:, misfire_limit:,
          overlap_policy:, max_concurrency:, jitter_window:,
          payload_ref:, thread_policy:, capability_grant:,
          behavior_version:, approval_profile:, delivery_policy:,
          budgets:, created_by:, created_at:
        }.freeze
      end

      def validate_id!(value)
        unless value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_.-]{0,255}\z/)
          raise Tamoz::ConfigurationError,
                "schedule id must be a bounded lowercase identifier"
        end
        value.freeze
      end

      def validate_revision!(value)
        unless value.is_a?(Integer) && value >= 1
          raise Tamoz::ConfigurationError, "schedule revision must be a positive integer"
        end
        value
      end

      def validate_kind!(kind, expression)
        unless KINDS.include?(kind)
          raise Tamoz::ConfigurationError,
                "schedule kind must be one of #{KINDS.inspect} (cron is a recorded deferral)"
        end
        unless expression.is_a?(String) && !expression.empty?
          raise Tamoz::ConfigurationError, "schedule expression must be a non-empty string"
        end
        kind
      end

      def validate_times!(kind, expression, start_at, end_at)
        validate_time!(start_at, "start_at") unless start_at.nil?
        validate_time!(end_at, "end_at") unless end_at.nil?
        if start_at && end_at && start_at > end_at
          raise Tamoz::ConfigurationError, "start_at must not exceed end_at"
        end

        validate_expression!(kind, expression)
      end

      def validate_expression!(kind, expression)
        case kind
        when :at
          unless expression.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
            raise Tamoz::ConfigurationError,
                  "at expression must be an ISO-8601 UTC instant (YYYY-MM-DDTHH:MM:SSZ)"
          end

          # The shape is not the instant: `2024-13-99T25:61:61Z` matches the
          # pattern and is not a time. Resolving it here means the operator
          # learns at `schedule add`, not the poller at fire time.
          self.class.at_instant(expression)
        when :interval
          unless expression.match?(/\A\d+\z/) && expression.to_i.positive?
            raise Tamoz::ConfigurationError,
                  "interval expression must be a positive integer duration in seconds"
          end
        end
      end

      def validate_enum!(value, set, name)
        unless set.include?(value)
          raise Tamoz::ConfigurationError, "#{name} must be one of #{set.inspect}"
        end
        value
      end

      def validate_limit!(value, name)
        unless value.is_a?(Integer) && value >= 0 && value <= MAX_BUDGET_MAGNITUDE
          raise Tamoz::ConfigurationError, "#{name} must be a bounded non-negative integer"
        end
        value
      end

      def validate_digest!(value, name)
        raise Tamoz::ConfigurationError, "#{name} must be a sha256:... digest" unless Tamoz::Core.valid_digest?(value)

        value.freeze
      end

      def validate_string!(value, name)
        unless value.is_a?(String) && !value.strip.empty? && value.bytesize <= 4096
          raise Tamoz::ConfigurationError, "#{name} must be a bounded non-empty string"
        end
        value.freeze
      end

      def validate_hash!(value, name)
        unless value.is_a?(Hash) && !value.empty?
          raise Tamoz::ConfigurationError, "#{name} must be a non-empty hash"
        end
        Tamoz::Core.deep_freeze(value)
      end

      def validate_budgets!(value)
        unless value.is_a?(Hash) && !value.empty?
          raise Tamoz::ConfigurationError, "budgets must be a non-empty hash"
        end
        %w[max_steps max_wall_seconds max_cost_tokens].each do |key|
          next unless value.key?(key)
          next if value[key].is_a?(Integer) && value[key].positive?

          raise Tamoz::ConfigurationError,
                "budgets.#{key} must be a positive integer"
        end
        Tamoz::Core.deep_freeze(value)
      end

      def validate_time!(value, name)
        unless value.is_a?(Integer) && value.positive?
          raise Tamoz::ConfigurationError, "#{name} must be a positive UTC epoch second"
        end
        value
      end
    end
  end
end
