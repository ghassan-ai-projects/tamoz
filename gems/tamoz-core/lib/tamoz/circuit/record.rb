# frozen_string_literal: true

module Tamoz
  module Circuit
    # DR-2 §2 — the ONE circuit record. Immutable: every transition returns a
    # NEW record, and the caller persists `#to_payload` with a CAS append. All
    # threshold/window/rate predicates are evaluated INSIDE the transition that
    # produces the new payload, so a crash can never land between "the counter
    # crossed" and "the state opened" (DR-2 C1).
    #
    # Stored shape (string keys — StateCodec does not support symbols and sorts
    # object keys, so this serializes canonically):
    #
    #   {"format_version" => 1, "scope_type" =>, "scope_id" =>,
    #    "state" => "closed"|"open", "threshold" =>,
    #    "owners" => {"<owner_id>" => {"failures" =>, "conditions" => {...}}},
    #    "conditions_met" => [ <typed evidence, ring-buffered> ],
    #    "opened_at_wall_ms" =>, "probe_window_ms" => <duration, not absolute>,
    #    "reset_authority" =>, "last_reset_at" =>, "last_reset_evidence" =>,
    #    "last_failure" => {"kind" =>, "context_digest" =>, "owner" =>, ...}}
    #
    # No caller-supplied context is stored verbatim; only digests are.
    class Record
      KEYS = %w[
        conditions_met format_version last_failure last_reset_at
        last_reset_evidence opened_at_wall_ms owners probe_window_ms
        reset_authority scope_id scope_type state threshold
      ].freeze

      attr_reader :scope, :payload

      class << self
        def initial(scope:, scope_id:, now_ms:)
          resolved = Registry.fetch(scope)
          new(
            scope: resolved,
            payload: {
              "format_version" => FORMAT_VERSION,
              "scope_type" => resolved.scope_type,
              "scope_id" => Circuit.identity!(scope_id, name: "circuit scope id"),
              "state" => "closed",
              "threshold" => resolved.threshold,
              "owners" => {},
              "conditions_met" => [],
              "opened_at_wall_ms" => nil,
              "probe_window_ms" => resolved.probe_window_ms,
              "reset_authority" => resolved.reset_authority,
              "last_reset_at" => nil,
              "last_reset_evidence" => nil,
              "last_failure" => nil
            },
            now_ms:
          )
        end

        # Invariant 18: a newer format version fails BEFORE any partial load; a
        # shape violation is a corruption, which the caller's store turns into a
        # fail-closed `open` scope (DR-2 C6).
        def load(payload, scope:, scope_id: nil)
          resolved = Registry.fetch(scope)
          unless payload.is_a?(Hash)
            corrupt!("a circuit record must be a mapping")
          end
          version = payload["format_version"]
          unless version.is_a?(Integer)
            corrupt!("a circuit record must carry an integer format version")
          end
          if version > FORMAT_VERSION
            raise CheckpointVersionError,
                  "unsupported circuit record format version #{version}"
          end

          validate!(payload, resolved, scope_id)
          new(scope: resolved, payload: payload, now_ms: nil)
        end

        def corrupt!(reason)
          raise CheckpointCorruptionError, "circuit record is invalid: #{reason}"
        end

        private

        def validate!(payload, scope, scope_id)
          extra = payload.keys.map(&:to_s) - KEYS
          corrupt!("unexpected keys #{extra.sort.join(", ")}") unless extra.empty?
          missing = KEYS - payload.keys.map(&:to_s)
          corrupt!("missing keys #{missing.sort.join(", ")}") unless missing.empty?

          unless payload["scope_type"] == scope.scope_type
            corrupt!("scope type does not match its namespace")
          end
          unless payload["scope_id"].is_a?(String) && !payload["scope_id"].empty?
            corrupt!("scope id is missing")
          end
          if scope_id && payload["scope_id"] != scope_id.to_s
            corrupt!("scope id does not match its key digest")
          end
          unless STATES.include?(payload["state"])
            corrupt!("state must be #{STATES.join(" or ")}")
          end
          unless payload["threshold"].is_a?(Integer) && payload["threshold"] >= 1
            corrupt!("threshold must be an integer >= 1")
          end
          unless payload["probe_window_ms"].is_a?(Integer) && payload["probe_window_ms"].positive?
            corrupt!("probe_window_ms must be a positive duration")
          end
          unless payload["reset_authority"].is_a?(String) && !payload["reset_authority"].empty?
            corrupt!("reset_authority is missing")
          end
          validate_time!(payload["opened_at_wall_ms"], "opened_at_wall_ms")
          validate_time!(payload["last_reset_at"], "last_reset_at")
          unless payload["last_reset_evidence"].nil? ||
                 DIGEST_PATTERN.match?(payload["last_reset_evidence"].to_s)
            corrupt!("last_reset_evidence must be a digest")
          end
          if payload["state"] == "open" && payload["opened_at_wall_ms"].nil?
            corrupt!("an open circuit must record when it opened")
          end
          validate_owners!(payload["owners"], scope)
          validate_conditions_met!(payload["conditions_met"])
          validate_last_failure!(payload["last_failure"])
        end

        def validate_time!(value, name)
          return if value.nil?
          return if value.is_a?(Integer) && !value.negative?

          corrupt!("#{name} must be a non-negative integer")
        end

        def validate_owners!(owners, scope)
          corrupt!("owners must be a mapping") unless owners.is_a?(Hash)
          if owners.length > MAX_CIRCUIT_OWNERS
            corrupt!("owners exceed the #{MAX_CIRCUIT_OWNERS} bound")
          end

          owners.each do |owner_id, state|
            unless owner_id.is_a?(String) && !owner_id.empty? &&
                   owner_id.bytesize <= MAX_IDENTITY_BYTES
              corrupt!("an owner id is invalid")
            end
            corrupt!("owner #{owner_id} state must be a mapping") unless state.is_a?(Hash)
            unless (state.keys.map(&:to_s) - %w[conditions failures]).empty?
              corrupt!("owner #{owner_id} state has unexpected keys")
            end
            unless state["failures"].is_a?(Integer) && !state["failures"].negative?
              corrupt!("owner #{owner_id} failure count is invalid")
            end
            conditions = state["conditions"]
            corrupt!("owner #{owner_id} conditions must be a mapping") unless conditions.is_a?(Hash)
            conditions.each do |condition_id, sub|
              unless scope.condition(condition_id)
                corrupt!("owner #{owner_id} carries unregistered condition #{condition_id}")
              end
              validate_sub_state!(sub, condition_id, owner_id)
            end
          end
        end

        def validate_sub_state!(sub, condition_id, owner_id)
          corrupt!("condition #{condition_id} sub-state must be a mapping") unless sub.is_a?(Hash)
          case sub["kind"]
          when "immediate"
            unless sub["count"].is_a?(Integer) && !sub["count"].negative?
              corrupt!("condition #{condition_id} count is invalid")
            end
          when "window", "rate"
            events = sub["events"]
            unless events.is_a?(Array) && events.length <= MAX_WINDOW_EVENTS
              corrupt!("condition #{condition_id} events exceed the #{MAX_WINDOW_EVENTS} bound")
            end
            events.each do |event|
              unless event.is_a?(Hash) && event["observed_at_ms"].is_a?(Integer)
                corrupt!("condition #{condition_id} carries an invalid event")
              end
            end
          when "run"
            counts = sub["counts"]
            unless counts.is_a?(Hash) && counts.length <= MAX_RUN_FINGERPRINTS &&
                   counts.values.all? { |value| value.is_a?(Integer) && !value.negative? }
              corrupt!("condition #{condition_id} run counts are invalid")
            end
          else
            corrupt!("condition #{condition_id} sub-state kind is unknown for owner #{owner_id}")
          end
        end

        def validate_conditions_met!(entries)
          corrupt!("conditions_met must be a list") unless entries.is_a?(Array)
          if entries.length > MAX_CONDITIONS_MET
            corrupt!("conditions_met exceeds the #{MAX_CONDITIONS_MET} bound")
          end

          entries.each do |entry|
            unless entry.is_a?(Hash) && DIGEST_PATTERN.match?(entry["digest"].to_s) &&
                   entry["observed_at_ms"].is_a?(Integer)
              corrupt!("a conditions_met entry is invalid")
            end
          end
        end

        def validate_last_failure!(value)
          return if value.nil?
          unless value.is_a?(Hash) && value["kind"].is_a?(String)
            corrupt!("last_failure is invalid")
          end
          unless value["context_digest"].nil? ||
                 DIGEST_PATTERN.match?(value["context_digest"].to_s)
            corrupt!("last_failure context digest is invalid")
          end
        end
      end

      def initialize(scope:, payload:, now_ms:)
        @scope = scope
        @payload = payload
        @created_now_ms = now_ms
        freeze
      end

      def scope_type = payload.fetch("scope_type")
      def scope_id = payload.fetch("scope_id")
      def state = payload.fetch("state")
      def threshold = payload.fetch("threshold")
      def owners = payload.fetch("owners")
      def conditions_met = payload.fetch("conditions_met")
      def opened_at_wall_ms = payload.fetch("opened_at_wall_ms")
      def probe_window_ms = payload.fetch("probe_window_ms")
      def reset_authority = payload.fetch("reset_authority")
      def last_reset_at = payload.fetch("last_reset_at")
      def last_reset_evidence = payload.fetch("last_reset_evidence")
      def last_failure = payload.fetch("last_failure")

      # A fresh, mutable copy for persistence.
      def to_payload
        deep_copy(payload)
      end

      def owner_failures(owner_id)
        owners.dig(owner_id.to_s, "failures") || 0
      end

      def owner_admitted?(owner_id)
        owners.key?(owner_id.to_s)
      end

      def owners_full?
        owners.length >= MAX_CIRCUIT_OWNERS
      end

      # DR-2 C1 read-time rule: a CLOSED record whose counter/sub-state already
      # satisfies an open predicate is treated `open`. The evidence, not the
      # written verdict, is authoritative — so a kill between the
      # threshold-crossing failure and the write can never lose an open that the
      # evidence says should exist.
      def effective_state(now_ms:)
        return "open" if state == "open"

        met_conditions(now_ms: now_ms).empty? ? "closed" : "open"
      end

      def open?(now_ms:)
        effective_state(now_ms: now_ms) == "open"
      end

      # `:closed` / `:degraded` / `:open` — the health triple the P10 supervisor
      # surfaces. `:degraded` is derived, never stored.
      def health(now_ms:)
        return :open if open?(now_ms: now_ms)
        return :degraded if owners.each_value.any? { |entry| entry.fetch("failures", 0).positive? }

        :closed
      end

      # The self-heal append: same record, written through as `open` with the
      # evidence that made it so. Returns `self` when nothing needs healing.
      def healed(now_ms:)
        return self if state == "open"

        met = met_conditions(now_ms: now_ms)
        return self if met.empty?

        opened(met, now_ms: now_ms, reason: "self_heal")
      end

      # DR-2 §4: `probe_window_ms` permits probe/observation only. This NEVER
      # changes state, and a backend clock rollback (now < opened_at) reports
      # false — a rollback can never enable mutation early.
      def probe_allowed?(now_ms:)
        return false unless state == "open"

        opened = opened_at_wall_ms
        return false if opened.nil? || now_ms < opened

        now_ms - opened >= probe_window_ms
      end

      # DR-2 §7 / design §7: opening never blind-cuts an already-dispatched
      # non-idempotent effect. The per-scope rule is pinned in the registry.
      def in_flight_rule = scope.in_flight_rule

      def in_flight_disposition(dispatched:, idempotent: false)
        return :proceed unless dispatched
        return :complete_and_journal if scope.in_flight_rule == "complete_and_journal"
        return :reconcile if idempotent

        :journal_unknown
      end

      # --- transitions ------------------------------------------------------

      # ONE atomic read-modify-write body (DR-2 C1). Every predicate is
      # evaluated here, inside the same value that the caller then appends.
      def with_failure(owner_id:, kind: :transport, context_digest: nil, now_ms:,
                       run_id: nil, fingerprint: nil)
        owner = Circuit.owner_id!(owner_id)
        admit!(owner)
        failure_kind = Circuit.identity!(kind, name: "circuit failure kind")
        consuming = scope.conditions_for(failure_kind)

        next_owners = deep_copy(owners)
        entry = next_owners[owner] ||= {"failures" => 0, "conditions" => {}}
        consuming.each do |condition|
          case condition.kind
          when "consecutive"
            entry["failures"] = entry.fetch("failures", 0) + 1
          when "immediate"
            sub = entry["conditions"][condition.id] ||= {"kind" => "immediate", "count" => 0}
            sub["count"] += 1
            sub["last_at_ms"] = now_ms
          when "window"
            sub = entry["conditions"][condition.id] ||=
              {"kind" => "window", "window_ms" => condition.window_ms, "events" => []}
            sub["events"] = bound_events(
              prune(sub.fetch("events"), condition.window_ms, now_ms) +
                [{"digest" => context_digest, "observed_at_ms" => now_ms}]
            )
          when "run"
            # A run-scoped condition is meaningless without the run and the
            # fingerprint it counts; fail closed rather than counting a blank.
            if run_id.nil? || fingerprint.nil?
              raise ConfigurationError,
                    "condition #{condition.id} requires run_id: and fingerprint:"
            end
            sub = entry["conditions"][condition.id] ||=
              {"kind" => "run", "run_id" => nil, "counts" => {}}
            run = Circuit.identity!(run_id, name: "circuit run id")
            sub["counts"] = {} unless sub["run_id"] == run
            sub["run_id"] = run
            print = Circuit.identity!(fingerprint, name: "failure fingerprint")
            sub["counts"] = bound_counts(sub.fetch("counts"), print)
          when "rate"
            sub = entry["conditions"][condition.id] ||=
              {"kind" => "rate", "window_ms" => condition.window_ms, "events" => []}
            sub["events"] = bound_events(
              prune(sub.fetch("events"), condition.window_ms, now_ms) +
                [{"outcome" => "failure", "observed_at_ms" => now_ms}]
            )
          end
        end

        candidate = replace(
          "owners" => next_owners,
          "last_failure" => {
            "kind" => failure_kind,
            "context_digest" => context_digest,
            "owner" => owner,
            "observed_at_ms" => now_ms
          }
        )
        met = candidate.met_conditions(now_ms: now_ms)
        return candidate if met.empty? || state == "open"

        candidate.opened(met, now_ms: now_ms, reason: "threshold")
      end

      # DR-2 §4: a success resets THAT OWNER's consecutive counter and nothing
      # else. It never closes an open circuit, and it never clears another
      # owner's evidence or a window/run/rate accumulator (that is exactly what
      # makes those conditions non-consecutive, DR-2 C3/D1/D5).
      def with_success(owner_id:, now_ms:)
        owner = Circuit.owner_id!(owner_id)
        admit!(owner)

        next_owners = deep_copy(owners)
        entry = next_owners[owner] ||= {"failures" => 0, "conditions" => {}}
        entry["failures"] = 0
        scope.conditions.select(&:observes_every_outcome?).each do |condition|
          sub = entry["conditions"][condition.id] ||=
            {"kind" => "rate", "window_ms" => condition.window_ms, "events" => []}
          sub["events"] = bound_events(
            prune(sub.fetch("events"), condition.window_ms, now_ms) +
              [{"outcome" => "success", "observed_at_ms" => now_ms}]
          )
        end

        candidate = replace("owners" => next_owners)
        # A success can still leave a rate/window predicate satisfied; the
        # read-time rule keeps the verdict honest either way.
        return candidate if state == "open"

        met = candidate.met_conditions(now_ms: now_ms)
        met.empty? ? candidate : candidate.opened(met, now_ms: now_ms, reason: "threshold")
      end

      # DR-2 §5: the ONLY path back to `closed`. The gate is here, on the record
      # write, so no in-process caller can bypass it.
      def with_reset(evidence:, now_ms:)
        validated = Evidence.validate!(evidence, scope: scope)
        digest = Evidence.digest(validated)
        cleared = owners.to_h do |owner, _entry|
          [owner, {"failures" => 0, "conditions" => {}}]
        end

        replace(
          "state" => "closed",
          "owners" => cleared,
          "opened_at_wall_ms" => nil,
          "conditions_met" => [],
          "last_reset_at" => now_ms,
          "last_reset_evidence" => digest,
          "last_failure" => nil
        )
      end

      # DR-2 C2: the owner map is bounded; overflow fails closed and an owner is
      # retired only with the scope's reset-authority evidence.
      def with_retired_owner(owner_id:, evidence:, now_ms:)
        owner = Circuit.owner_id!(owner_id)
        unless owners.key?(owner)
          raise CircuitPolicyError, "the circuit does not carry that owner"
        end
        validated = Evidence.validate!(evidence, scope: scope)

        next_owners = deep_copy(owners)
        next_owners.delete(owner)
        replace(
          "owners" => next_owners,
          "conditions_met" => append_evidence(
            conditions_met,
            {
              "condition" => "owner_retired",
              "owner" => owner,
              "digest" => Evidence.digest(validated),
              "observed_at_ms" => now_ms
            }
          )
        )
      end

      # The repair record a corrupt payload is replaced by (DR-2 C6). Canonical
      # and closed, carrying the observed corrupt digest and the reset evidence.
      def self.repaired(scope:, scope_id:, evidence:, observed_digest:, now_ms:)
        resolved = Registry.fetch(scope)
        validated = Evidence.validate!(evidence, scope: resolved)
        base = initial(scope: resolved, scope_id: scope_id, now_ms: now_ms)
        base.__send__(
          :replace,
          "last_reset_at" => now_ms,
          "last_reset_evidence" => Evidence.digest(validated),
          "conditions_met" => [
            {
              "condition" => "corrupt_record_repaired",
              "owner" => nil,
              "digest" => Circuit.digest_of(
                {"observed_payload_digest" => String(observed_digest)},
                domain: CONDITIONS_DIGEST_DOMAIN
              ),
              "observed_at_ms" => now_ms
            }
          ]
        )
      end

      # --- predicates -------------------------------------------------------

      # Every condition currently satisfied, as evidence entries. Evaluated for
      # EVERY owner: any owner meeting the predicate opens the shared scope
      # record (DR-2 C2), and a healthy owner's success can never mask another
      # owner's accumulating failures.
      def met_conditions(now_ms:)
        result = []
        owners.each do |owner, entry|
          scope.conditions.each do |condition|
            next unless condition_met?(condition, entry, now_ms)

            result << {
              "condition" => condition.id,
              "owner" => owner,
              "digest" => Circuit.digest_of(
                {
                  "condition" => condition.id,
                  "owner" => owner,
                  "scope_type" => scope_type,
                  "scope_id" => scope_id,
                  "threshold" => condition.threshold,
                  "kind" => condition.kind
                },
                domain: CONDITIONS_DIGEST_DOMAIN
              ),
              "observed_at_ms" => now_ms
            }
          end
        end
        result
      end

      # The typed digest of the failure state a reset clears. Deterministic for
      # a given persisted failure state, so a reset can be correlated with the
      # failures that preceded it after a restart.
      def conditions_digest(identity = scope_id)
        Circuit.digest_of(
          {
            "scope_type" => scope_type,
            "scope_id" => String(identity),
            "failure_kind" => last_failure && last_failure["kind"],
            "context_digest" => last_failure && last_failure["context_digest"],
            "conditions" => conditions_met.map { |entry| entry["digest"] }.compact.sort
          },
          domain: CONDITIONS_DIGEST_DOMAIN
        )
      end

      # DR-2 §7/C1: the threshold-crossing append. `with_failure` and
      # `with_success` both call this on the CANDIDATE record (a different
      # instance), so it is part of the public transition surface, not a private
      # helper — a private `opened` would raise NoMethodError exactly when a
      # predicate first crosses (the threshold path the tests exercise).
      def opened(met, now_ms:, reason:)
        evidence = met.map do |entry|
          entry.merge("reason" => String(reason))
        end
        replace(
          "state" => "open",
          "opened_at_wall_ms" => opened_at_wall_ms || now_ms,
          "conditions_met" => evidence.reduce(conditions_met) do |carry, entry|
            append_evidence(carry, entry)
          end
        )
      end

      private

      def condition_met?(condition, entry, now_ms)
        case condition.kind
        when "consecutive"
          entry.fetch("failures", 0) >= condition.threshold
        when "immediate"
          (entry.dig("conditions", condition.id, "count") || 0) >= condition.threshold
        when "window"
          events = entry.dig("conditions", condition.id, "events") || []
          prune(events, condition.window_ms, now_ms).length >= condition.threshold
        when "run"
          counts = entry.dig("conditions", condition.id, "counts") || {}
          counts.each_value.any? { |value| value >= condition.threshold }
        when "rate"
          events = prune(
            entry.dig("conditions", condition.id, "events") || [],
            condition.window_ms, now_ms
          )
          return false if events.length < condition.min_samples

          failures = events.count { |event| event["outcome"] == "failure" }
          (failures.to_f / events.length) >= condition.max_rate
        else
          false
        end
      end

      def admit!(owner)
        return if owners.key?(owner)
        return unless owners_full?

        raise CircuitPolicyError,
              "the circuit owner map is full (#{MAX_CIRCUIT_OWNERS}); retire an " \
              "owner with the scope's reset evidence before admitting another"
      end

      # DR-2 C7: evidence is deduped by digest and deterministically ordered, so
      # two writers that race and merge land the SAME list regardless of arrival
      # order. Ring-buffered to `MAX_CONDITIONS_MET` (C8).
      def append_evidence(entries, entry)
        merged = entries.reject { |existing| existing["digest"] == entry["digest"] } + [entry]
        merged
          .sort_by { |item| [item["observed_at_ms"], item["digest"].to_s] }
          .last(MAX_CONDITIONS_MET)
      end

      def prune(events, window_ms, now_ms)
        return events if window_ms.nil? || now_ms.nil?

        events.select do |event|
          observed = event["observed_at_ms"]
          observed.is_a?(Integer) && observed <= now_ms && (now_ms - observed) < window_ms
        end
      end

      def bound_events(events)
        events.last(MAX_WINDOW_EVENTS)
      end

      def bound_counts(counts, fingerprint)
        next_counts = counts.to_h { |key, value| [key, value] }
        next_counts[fingerprint] = (next_counts[fingerprint] || 0) + 1
        return next_counts if next_counts.length <= MAX_RUN_FINGERPRINTS

        # Keep the highest counts (the ones nearest their threshold), then the
        # fingerprint just observed, so the bound can never drop live evidence.
        kept = next_counts.sort_by { |key, value| [-value, key] }.first(MAX_RUN_FINGERPRINTS).to_h
        kept[fingerprint] = next_counts.fetch(fingerprint)
        kept
      end

      def replace(changes)
        self.class.new(
          scope: scope,
          payload: to_payload.merge(changes.transform_keys(&:to_s)),
          now_ms: @created_now_ms
        )
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, entry| [key.dup, deep_copy(entry)] }
        when Array then value.map { |entry| deep_copy(entry) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
