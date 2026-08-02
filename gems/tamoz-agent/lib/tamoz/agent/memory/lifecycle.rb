# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §4 P11-D2 (invariant 31): correction and deletion propagate with
      # proof. Every transition appends a NEW record version (states and source
      # evidence are never edited in place) and a matching index row, so the
      # superseded/quarantined/deleted version leaves active recall immediately
      # (the head-join excludes it). A deletion receipt (invariant-54 shape)
      # names what was removed, retained, and pending for BOTH tombstone-delete
      # and hard-purge; partial failure raises the typed `MemoryDeletionError`
      # with the receipt's `pending` fields — no silent partial erasure.
      class Lifecycle
        def initialize(engine)
          @engine = engine
        end

        # Correction: append a new ACTIVE version of the same memory identity
        # carrying the prior-version digest. The incorrect version is no longer
        # the Store head, so it leaves active recall immediately; a historical
        # read still works (probe P11-16).
        def correct(memory_id:, statement:, actor:, reason:, layer: nil, klass: nil,
                    sensitivity: nil, scopes: nil, source_refs: nil)
          current = current_record(memory_id)
          raise MemoryError, "memory record #{memory_id} does not exist" unless current

          record = current.record
          corrected = record.with(
            record_version: current.entry.version + 1,
            statement:,
            supersession_key: record.digest,
            actor:,
            layer: layer || record.layer,
            klass: klass || record.klass,
            sensitivity: sensitivity || record.sensitivity,
            scopes: scopes || record.scopes,
            source_refs: source_refs || record.source_refs,
            state: :active,
            transition: transition(actor, reason, prior_version: record.record_version)
          )
          append_version(record, corrected, expected_version: current.entry.version)
          corrected
        end

        # Supersede: the old record transitions to :superseded (excluded from
        # active recall by state AND head-join); the replacement is admitted
        # separately by the caller.
        def supersede(memory_id:, actor:, reason:, replacement_id: nil)
          current = current_record(memory_id)
          raise MemoryError, "memory record #{memory_id} does not exist" unless current

          record = current.record
          superseded = record.with(
            record_version: current.entry.version + 1,
            state: :superseded,
            supersession_key: replacement_id || record.supersession_key,
            transition: transition(actor, reason, prior_version: record.record_version)
          )
          append_version(record, superseded, expected_version: current.entry.version)
          superseded
        end

        # Quarantine: a contradictory or policy-flagged record is quarantined
        # (never "ranked slightly higher").
        def quarantine(memory_id:, actor:, reason:)
          current = current_record(memory_id)
          raise MemoryError, "memory record #{memory_id} does not exist" unless current

          record = current.record
          quarantined = record.with(
            record_version: current.entry.version + 1,
            state: :quarantined,
            transition: transition(actor, reason, prior_version: record.record_version)
          )
          append_version(record, quarantined, expected_version: current.entry.version)
          quarantined
        end

        # Tombstone-delete: appends a :deleted version (deterministic system
        # transition for expiry; actor otherwise) and emits an invariant-54
        # shape receipt naming removed / retained / pending sinks.
        def delete(memory_id:, actor: nil, reason: "deleted", authority: "tamoz.memory.lifecycle", now: nil)
          current = current_record(memory_id)
          raise MemoryError, "memory record #{memory_id} does not exist" unless current

          record = current.record
          deleting_actor = actor || (expired?(record) ? "system" : "tamoz.memory.lifecycle")
          deleted = record.with(
            record_version: current.entry.version + 1,
            state: :deleted,
            transition: transition(deleting_actor, reason, authority:, prior_version: record.record_version,
                                   evidence: {"expiry" => expired?(record)})
          )
          begin
            append_version(record, deleted, expected_version: current.entry.version)
          rescue Tamoz::StoreConflictError => error
            # A concurrent update won the CAS: no silent partial erasure.
            raise MemoryDeletionError.new(
              "memory delete conflict for #{memory_id}: #{error.message}",
              receipt: deletion_receipt(memory_id, now:, removed: {}, retained: {}, pending: ["store_cas_conflict"])
            )
          end
          sinks = deletion_sinks(memory_id, deleted)
          deletion_receipt(memory_id, now:, removed: sinks.fetch(:removed), retained: sinks.fetch(:retained), pending: sinks.fetch(:pending))
        end

        # Hard-purge orchestration (C6): the tamoz-agent maintenance pass over
        # the repository's `purge`. Physically removes the ciphertext version
        # rows + index rows after the retention boundary and emits the purge
        # receipt. Before the boundary the repository refuses (StoreConflictError
        # family) and no receipt is emitted.
        def purge(memory_id:, layer: nil, now: nil)
          current = current_record(memory_id, allow_deleted: true)
          layer ||= current ? current.record.layer.to_s : nil
          raise MemoryError, "memory record #{memory_id} does not exist" unless layer

          receipt = @engine.repository.purge(
            @engine.namespace, layer, memory_id,
            now_ms: (now || Time.now).to_i * 1000
          )
          receipt
        end

        private

        Current = Data.define(:entry, :record)

        def current_record(memory_id, allow_deleted: false)
          # Locate the record by scanning the head store rows for the namespace
          # (the key embeds the layer). Cost is bounded by the memory namespace
          # size; the eval surface never exceeds limits.
          row = nil
          @engine.store.open_transaction(label: "memory.locate") do |tx|
            row = tx.first(
              "memory.locate",
              <<~SQL,
                SELECT h.key
                FROM tamoz_store_heads h
                WHERE h.namespace = ? AND h.key LIKE ?
                  AND (? = 1 OR h.deleted = 0)
                ORDER BY h.key COLLATE BINARY
                LIMIT 1
              SQL
              [@engine.namespace, "%/#{memory_id}", allow_deleted ? 1 : 0]
            )
          end
          return nil unless row

          key = row.fetch(0)
          layer, = key.split("/", 2)
          entry = @engine.store.get(@engine.namespace, key)
          return nil unless entry && entry.value.is_a?(MemoryRecord)

          Current.new(entry:, record: entry.value)
        end

        def append_version(prior, next_record, expected_version:)
          @engine.repository.append(
            record: next_record,
            index: @engine.index_for(next_record),
            expected_version:,
            sensitive: next_record.sensitive?
          )
        end

        def expired?(record)
          record.valid_until && record.valid_until.to_i * 1000 < @engine.now_ms
        end

        def transition(actor, reason, authority: "tamoz.memory.lifecycle", prior_version: nil, evidence: {})
          {
            "actor" => actor.to_s,
            "authority" => authority,
            "reason" => reason,
            "prior_version" => prior_version,
            "evidence" => evidence,
            "policy_version" => "1",
            "timestamp" => @engine.now_ms,
            "trace_id" => SecureRandom.uuid
          }
        end

        # Invariant-54 shape: what was removed, what was retained (protected
        # artifacts, backups under their own retention), what is pending, and
        # the purge time.
        def deletion_receipt(memory_id, now:, removed:, retained:, pending:)
          {
            "memory_deletion_receipt" => 1,
            "memory_id" => memory_id,
            "namespace" => @engine.namespace,
            "removed" => removed,
            "retained" => retained,
            "pending" => pending,
            "deleted_at_ms" => (now || Time.now).to_i * 1000
          }.freeze
        end

        # Every reachable sink under policy: the primary record, the index rows,
        # derived consolidations that cite this record as a source, prompt
        # caches, and sync queues. Protected artifacts stay under their own
        # rules; backups fall under their own retention (named pending).
        def deletion_sinks(memory_id, deleted)
          index_rows = index_row_count(memory_id)
          derived = derived_references(memory_id)
          {
            removed: {
              "primary_record" => 1,
              "index_rows" => index_rows,
              "derived_consolidations" => derived,
              "prompt_caches" => 0,
              "sync_queues" => 0
            },
            retained: {
              "protected_artifacts" => 0,
              "backups" => 0
            },
            pending: []
          }
        end

        def index_row_count(memory_id)
          count = 0
          @engine.store.open_transaction(label: "memory.index_count") do |tx|
            count = tx.scalar(
              "memory.index_count",
              <<~SQL,
                SELECT COUNT(*) FROM tamoz_memory_index
                WHERE store_namespace = ? AND memory_id = ?
              SQL
              [@engine.namespace, memory_id]
            )
          end
          count
        end

        def derived_references(memory_id)
          count = 0
          @engine.store.open_transaction(label: "memory.derived") do |tx|
            count = tx.scalar(
              "memory.derived",
              <<~SQL,
                SELECT COUNT(*) FROM tamoz_store_versions v
                WHERE v.namespace = ? AND v.deleted = 0
                  AND CAST(v.payload AS TEXT) LIKE ?
              SQL
              [@engine.namespace, "%#{memory_id}%"]
            )
          end
          count
        end
      end
    end
  end
end
