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
      # One failure occurrence: what failed and the evidence identifying it.
      # Grouped so `with_failure` names only the actor (owner) and the clock
      # alongside it, rather than spreading four occurrence fields across its
      # signature.
      FailureEvent = Data.define(:kind, :context_digest, :run_id, :fingerprint) do
        def initialize(kind: :transport, context_digest: nil, run_id: nil, fingerprint: nil)
          super
        end
      end

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
          RecordSchema.validate!(payload, resolved, scope_id)
          new(scope: resolved, payload: payload, now_ms: nil)
        end
      end

      def initialize(scope:, payload:, now_ms:)
        @scope = scope
        # `freeze` on the record alone froze the reference, not the state. The
        # payload arrived from the caller (`load` handed it straight through)
        # and `owners`/`conditions_met` return the live containers, so anything
        # holding a loaded record could mutate "durable" circuit state in place
        # — the exact opposite of "every transition returns a NEW record".
        # `to_payload` already deep-copies on the way out; this is the same
        # discipline on the way in.
        @payload = Tamoz::Core.deep_freeze(payload)
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
        Tamoz::Core.deep_dup(payload)
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
      def with_failure(owner_id:, now_ms:, event: FailureEvent.new)
        owner = admitted_owner(owner_id)
        failure_kind = Circuit.identity!(event.kind, name: "circuit failure kind")
        next_owners = Tamoz::Core.deep_dup(owners)
        entry = next_owners[owner] ||= OwnerTally.blank_entry
        OwnerTally.record_failure(entry, scope.conditions_for(failure_kind), event, now_ms:)
        settle(failed_candidate(owner, failure_kind, next_owners, event.context_digest, now_ms), now_ms)
      end

      # DR-2 §4: a success resets THAT OWNER's consecutive counter and nothing
      # else. It never closes an open circuit, and it never clears another
      # owner's evidence or a window/run/rate accumulator (that is exactly what
      # makes those conditions non-consecutive, DR-2 C3/D1/D5).
      def with_success(owner_id:, now_ms:)
        owner = admitted_owner(owner_id)
        next_owners = Tamoz::Core.deep_dup(owners)
        entry = next_owners[owner] ||= OwnerTally.blank_entry
        OwnerTally.record_success(entry, scope.conditions.select(&:observes_every_outcome?), now_ms:)
        settle(replace("owners" => next_owners), now_ms)
      end

      # DR-2 §5: the ONLY path back to `closed`. The gate is here, on the record
      # write, so no in-process caller can bypass it.
      def with_reset(evidence:, now_ms:)
        validated = Evidence.validate!(evidence, scope: scope)
        digest = Evidence.digest(validated)
        cleared = owners.transform_values { OwnerTally.blank_entry }

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
        raise CircuitPolicyError, "the circuit does not carry that owner" unless owners.key?(owner)

        validated = Evidence.validate!(evidence, scope: scope)
        retirement = {
          "condition" => "owner_retired", "owner" => owner,
          "digest" => Evidence.digest(validated), "observed_at_ms" => now_ms
        }
        replace("owners" => owners.except(owner), "conditions_met" => append_evidence(conditions_met, retirement))
      end

      # The repair record a corrupt payload is replaced by (DR-2 C6). Canonical
      # and closed, carrying the observed corrupt digest and the reset evidence.
      def self.repaired(scope:, scope_id:, evidence:, observed_digest:, now_ms:)
        resolved = Registry.fetch(scope)
        validated = Evidence.validate!(evidence, scope: resolved)
        payload = initial(scope: resolved, scope_id: scope_id, now_ms: now_ms).to_payload.merge(
          "last_reset_at" => now_ms, "last_reset_evidence" => Evidence.digest(validated),
          "conditions_met" => [repair_evidence(observed_digest, now_ms)]
        )
        new(scope: resolved, payload: payload, now_ms: now_ms)
      end

      def self.repair_evidence(observed_digest, now_ms)
        digest = Circuit.digest_of({ "observed_payload_digest" => String(observed_digest) },
                                   domain: CONDITIONS_DIGEST_DOMAIN)
        { "condition" => "corrupt_record_repaired", "owner" => nil, "digest" => digest, "observed_at_ms" => now_ms }
      end
      private_class_method :repair_evidence

      # --- predicates -------------------------------------------------------

      # Every condition currently satisfied, as evidence entries. Evaluated for
      # EVERY owner: any owner meeting the predicate opens the shared scope
      # record (DR-2 C2), and a healthy owner's success can never mask another
      # owner's accumulating failures.
      def met_conditions(now_ms:)
        owners.flat_map do |owner, entry|
          scope.conditions
               .select { |condition| OwnerTally.met?(condition, entry, now_ms) }
               .map { |condition| met_evidence(condition, owner, now_ms) }
        end
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

      def met_evidence(condition, owner, now_ms)
        { "condition" => condition.id, "owner" => owner, "digest" => condition_digest(condition, owner),
          "observed_at_ms" => now_ms }
      end

      def condition_digest(condition, owner)
        Circuit.digest_of(
          { "condition" => condition.id, "owner" => owner, "scope_type" => scope_type, "scope_id" => scope_id,
            "threshold" => condition.threshold, "kind" => condition.kind },
          domain: CONDITIONS_DIGEST_DOMAIN
        )
      end

      def admitted_owner(owner_id)
        owner = Circuit.owner_id!(owner_id)
        return owner if owners.key?(owner) || !owners_full?

        raise CircuitPolicyError,
              "the circuit owner map is full (#{MAX_CIRCUIT_OWNERS}); retire an " \
              "owner with the scope's reset evidence before admitting another"
      end

      def settle(candidate, now_ms)
        return candidate if state == "open"

        met = candidate.met_conditions(now_ms: now_ms)
        met.empty? ? candidate : candidate.opened(met, now_ms: now_ms, reason: "threshold")
      end

      def failed_candidate(owner, failure_kind, next_owners, context_digest, now_ms)
        replace(
          "owners" => next_owners,
          "last_failure" => {
            "kind" => failure_kind,
            "context_digest" => context_digest,
            "owner" => owner,
            "observed_at_ms" => now_ms
          }
        )
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

      def replace(changes)
        self.class.new(
          scope: scope,
          payload: to_payload.merge(changes.transform_keys(&:to_s)),
          now_ms: @created_now_ms
        )
      end
    end
  end
end
