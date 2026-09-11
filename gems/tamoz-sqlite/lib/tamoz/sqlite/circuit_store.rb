# frozen_string_literal: true

module Tamoz
  module SQLite
    # DR-2 — the durable circuit record adapter (docs/DR2_DURABLE_CIRCUIT_PLAN.md).
    #
    # There is exactly one circuit engine in this repository (`Tamoz::Circuit`,
    # tamoz-core); the SQLite store is a thin persistence adapter over it:
    #
    #   namespace `tamoz.circuit.<scope_type>`, key `<scope_digest>`
    #   (`Circuit.namespace_for` / `Circuit.scope_digest`), value = the
    #   `Circuit::Record` payload.
    #
    # The record is IMMUTABLE: every transition (`with_failure`, `with_success`,
    # `with_reset`) returns a NEW record and the store persists `#to_payload`
    # with a CAS append (`Store#put if_version:`) so the threshold predicate is
    # evaluated INSIDE the value that is then appended (DR-2 C1). A concurrent
    # writer's conflict is retried with a bounded re-read (DR-2 C7 merge
    # protocol); the evidence list dedupes by digest and sorts deterministically,
    # so two racing writers land the same merged list regardless of arrival order.
    #
    # Corruption (DR-2 C6): a payload the Store cannot decode surfaces as
    # `Tamoz::CheckpointCorruptionError` from `Store#get`; the scope then fails
    # closed (`open?` reports true, transitions are observation-only). The
    # authority-gated repair lives here as `#repair_corrupt`, which reads the
    # RAW head row inside one transaction (ordinary get→put CAS cannot, because
    # the corrupt payload never decodes), verifies the observed corrupt digest
    # and the reset evidence, and appends the canonical closed repair record.
    #
    # Restart identity (DR-2 D10): `owner_id` is a stable deployment/policy
    # identity (`Circuit.owner_id!` refuses UUID churn), so a restarted
    # component reuses its own evidence instead of orphaning it.
    class CircuitStore
      MAX_CAS_ATTEMPTS = 5

      # The Store normalizes namespace/key with SafeText at this byte bound
      # (Store::MAX_NAME_BYTES is private; the value is the documented 1024).
      STORE_NAME_MAX_BYTES = 1_024

      # The one interface both consumers already use
      # (`Healing::Seams::MemoryCircuitStore` and `Tamoz::Mcp::MemoryCircuitStore`
      # contract, DR-2 §8): `scope`, `open?`, `failures`, `record_failure`,
      # `record_success`, `reset(evidence:)`, `reset_evidence`,
      # `last_failure_kind`, `last_failure_context`, `conditions_digest`.
      attr_reader :store, :scope_type, :scope_id, :owner_id

      def initialize(store:, scope:, scope_id:, owner_id:, clock: -> { Time.now })
        @store = store
        @scope_type = Tamoz::Circuit::Registry.fetch(scope).scope_type
        @scope_id = Tamoz::Circuit.identity!(scope_id, name: "circuit scope id")
        @owner_id = Tamoz::Circuit.owner_id!(owner_id)
        @clock = clock
        @namespace = Tamoz::Circuit.namespace_for(@scope_type)
        @key = Tamoz::Circuit.scope_digest(scope_type: @scope_type, scope_id: @scope_id)
      end

      def scope = @scope_type

      def now_ms
        @clock.call.to_i * 1000
      end

      # --- read ------------------------------------------------------------

      # The current record, or a fresh initial record when none exists yet.
      def read_record
        entry = @store.get(@namespace, @key)
        return initial_record unless entry

        Tamoz::Circuit::Record.load(entry.value, scope: @scope_type, scope_id: @scope_id)
      end

      # DR-2 §2/C1: `effective_state` re-evaluates every condition on READ, so a
      # crash between "counter crossed" and "state opened" (D9) still reports
      # open from the evidence. Corruption fails closed the same way.
      def open?
        return true if corrupt?

        read_record.open?(now_ms: now_ms)
      end

      def failures
        return 0 if corrupt?

        read_record.owner_failures(@owner_id)
      end

      def reset_evidence
        return nil if corrupt?

        read_record.last_reset_evidence
      end

      def last_failure_kind
        return nil if corrupt?

        failure = read_record.last_failure
        failure && failure["kind"]&.to_sym
      end

      def last_failure_context
        return nil if corrupt?

        failure = read_record.last_failure
        failure && failure["context_digest"]
      end

      def conditions_digest(identity = @scope_id)
        return nil if corrupt?

        read_record.conditions_digest(identity)
      end

      # --- transitions ------------------------------------------------------

      # One atomic read-modify-write (DR-2 C1). The transition is evaluated
      # inside the CAS body; a concurrent append conflicts and is retried from a
      # fresh read, bounded.
      def record_failure(kind: :transport, context: nil)
        return :open if corrupt?

        record = cas do |current|
          current.with_failure(
            owner_id: @owner_id,
            now_ms: now_ms,
            event: Tamoz::Circuit::Record::FailureEvent.new(
              kind:, context_digest: Tamoz::Circuit.context_digest(context)
            )
          )
        end
        record.health(now_ms: now_ms)
      end

      def record_success
        return :open if corrupt?

        record = cas do |current|
          current.with_success(owner_id: @owner_id, now_ms: now_ms)
        end
        record.health(now_ms: now_ms)
      end

      # The ONLY path back to `closed`. The evidence gate lives on the record
      # write (`Record#with_reset` → `Circuit::Evidence.validate!`), so no
      # in-process caller can bypass it; a refusal raises
      # `Tamoz::CircuitPolicyError` and the circuit stays open.
      def reset(evidence: nil)
        cas do |current|
          current.with_reset(evidence:, now_ms: now_ms)
        end
        :closed
      end

      # DR-2 C6/DC-2b: repair a corrupt record, fail-closed. `evidence:` must
      # satisfy the scope's reset authority; `expected_payload_digest` must
      # match the digest of the raw head currently stored — a mismatch means the
      # record changed since the corruption was observed, and the repair refuses
      # rather than clobbering it. Appends the canonical closed repair record in
      # ONE transaction. No generic raw-Store overwrite is exposed.
      def repair_corrupt(scope:, evidence:, expected_payload_digest:)
        resolved = Tamoz::Circuit::Registry.fetch(scope)
        validated = Tamoz::Circuit::Evidence.validate!(evidence, scope: resolved)
        unless expected_payload_digest.is_a?(String) &&
               Tamoz::Circuit::DIGEST_PATTERN.match?(expected_payload_digest)
          raise Tamoz::ConfigurationError,
                "expected_payload_digest must be a sha256:... digest"
        end

        namespace_text = normalize_name(@namespace, label: "Store namespace")
        key_text = normalize_name(@key, label: "Store key")
        repaired = nil
        @store.open_transaction(label: "circuit.repair") do |tx|
          row = tx.first(
            "circuit.repair.head",
            <<~SQL,
              SELECT h.current_version, v.payload_digest, v.deleted
              FROM tamoz_store_heads h
              JOIN tamoz_store_versions v
                ON v.namespace = h.namespace
               AND v.key = h.key
               AND v.version = h.current_version
              WHERE h.namespace = ? AND h.key = ?
            SQL
            [namespace_text, key_text]
          )
          unless row
            raise Tamoz::CheckpointCorruptionError,
                  "no circuit record exists to repair"
          end
          unless row.fetch(2) == 0
            raise Tamoz::CheckpointCorruptionError,
                  "the circuit record head is deleted; repair is not applicable"
          end
          stored_digest = row.fetch(1)
          unless secure_digest_equal?(stored_digest, expected_payload_digest)
            raise Tamoz::CircuitPolicyError,
                  "the stored circuit payload digest no longer matches the " \
                  "observed corrupt digest; the record changed since observation"
          end

          repaired_record = Tamoz::Circuit::Record.repaired(
            scope: resolved,
            scope_id: @scope_id,
            evidence: validated,
            observed_digest: expected_payload_digest,
            now_ms: now_ms
          )
          bytes = @store.state_codec.dump(repaired_record.to_payload)
          entry, = @store.append_in_transaction(
            tx,
            namespace: @namespace,
            key: @key,
            expected: row.fetch(0),
            bytes:,
            sensitive: false,
            deleted: false
          )
          repaired = entry.value
        end
        repaired
      end

      # --- helpers ----------------------------------------------------------

      # A corrupt payload surfaces as `CheckpointCorruptionError` — either from
      # `Store#get` (bytes cannot decode) or from `Record.load` (bytes decode but
      # the record shape is invalid). Every read re-checks so a record corrupted
      # AFTER a clean read still fails closed (no stale cached verdict).
      def corrupt?
        read_record
        false
      rescue Tamoz::CheckpointCorruptionError
        true
      end

      private

      def initial_record
        Tamoz::Circuit::Record.initial(
          scope: @scope_type, scope_id: @scope_id, now_ms: now_ms
        )
      end

      # Bounded CAS: read → transition → append; on conflict, re-read and retry.
      def cas
        attempts = 0
        begin
          entry = @store.get(@namespace, @key)
          current = entry ? Tamoz::Circuit::Record.load(entry.value, scope: @scope_type, scope_id: @scope_id) : initial_record
          next_record = yield(current)
          @store.put(@namespace, @key, next_record.to_payload, if_version: entry&.version)
          next_record
        rescue Tamoz::StoreConflictError
          attempts += 1
          retry if attempts < MAX_CAS_ATTEMPTS

          raise
        end
      end

      # The Store normalizes namespace/key with SafeText (MAX_NAME_BYTES =
      # 1024); the raw repair read binds the SAME normalized forms so the query
      # matches the rows the Store wrote.
      def normalize_name(value, label:)
        SafeText.normalize(
          value,
          name: label,
          max_bytes: STORE_NAME_MAX_BYTES,
          error_class: Tamoz::ConfigurationError
        )
      end

      # Constant-time digest comparison (the tamoz-core convention for digests).
      def secure_digest_equal?(left, right)
        left = String(left)
        right = String(right)
        return false unless left.bytesize == right.bytesize

        difference = 0
        left.bytes.zip(right.bytes) do |left_byte, right_byte|
          difference |= left_byte ^ right_byte
        end
        difference.zero?
      end
    end
  end
end
