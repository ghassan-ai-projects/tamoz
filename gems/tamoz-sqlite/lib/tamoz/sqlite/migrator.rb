# frozen_string_literal: true

require "digest"

module Tamoz
  module SQLite
    class Migrator
      APPLICATION_ID = 0x54414D5A # TAMZ
      # P11 (three-layer memory): CURRENT_VERSION moves 1 -> 2 through the
      # checksummed MIGRATION_2, which adds the lexical memory index table
      # `tamoz_memory_index` (P11 plan §2/§4 P11-B). Ordinals are consumed
      # monotonically; a later phase cannot reuse ordinal 2 (the
      # monotonic-ordering test in test/sqlite_migration_test.rb asserts it).
      # P14 (streaming input) §11/C8: CURRENT_VERSION moves 4 -> 5 through
      # MIGRATION_5, which adds the processing-plane tables (operator state,
      # immutable Situation versions, trigger evaluations, outbox) on top of
      # the admission tables from MIGRATION_4. Existing tables are untouched;
      # a pre-P14 database loads with the stream disabled (legacy semantics,
      # never a partial load).
      # Comms (COMMS_DESIGN §13): 5 -> 6 through MIGRATION_6, the ten
      # channel-store tables. Ordinals are consumed monotonically and never
      # reused; the monotonic-ordering test pins the exact ordinal list.
      # ADR-049 (PLAN_ADR049 Phase 2): 8 -> 9 through MIGRATION_9, which pins
      # the prompt's required_evidence (INV-C).
      # ADR-049 (PLAN_ADR049 Phase 4): 9 -> 10 through MIGRATION_10, which
      # records the decision audit trail — the evidence level that made an
      # approve legal and why (contract §7.1).
      # JCS digest-rule cutover (PLAN_TAMOZ_STREAM_BUILD T0.1): 10 -> 11 through
      # MIGRATION_11, which registers the digest epoch and clears the rows whose
      # digests embedded the pre-RFC-8785 canonical serialization.
      # Situation-scoped memory (PLAN_TAMOZ_STREAM_BUILD T0.3): 11 -> 12 through
      # MIGRATION_12, which adds the situation/entity scope columns to the
      # memory index.
      CURRENT_VERSION = 14

      # The digest rule generation marker written by MIGRATION_11. Bumped by a
      # future forward migration whenever the canonical digest rule changes.
      DIGEST_EPOCH = 1

      MIGRATION_1 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_schema_migrations (
            version INTEGER PRIMARY KEY,
            checksum TEXT NOT NULL,
            applied_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_threads (
            thread_id TEXT PRIMARY KEY,
            tombstone_id TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_namespaces (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            active_checkpoint_id TEXT,
            next_checkpoint_sequence INTEGER NOT NULL DEFAULT 0
              CHECK (next_checkpoint_sequence >= 0),
            next_request_sequence INTEGER NOT NULL DEFAULT 0
              CHECK (next_request_sequence >= 0),
            lease_owner_id TEXT,
            lease_fence INTEGER NOT NULL DEFAULT 0 CHECK (lease_fence >= 0),
            lease_expires_at_ms INTEGER,
            greatest_backend_time_ms INTEGER NOT NULL DEFAULT 0
              CHECK (greatest_backend_time_ms >= 0),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace),
            FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_checkpoints (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence >= 0),
            parent_id TEXT,
            format_version INTEGER NOT NULL CHECK (format_version > 0),
            graph_name TEXT NOT NULL,
            graph_version TEXT NOT NULL,
            digest_version INTEGER NOT NULL CHECK (digest_version > 0),
            definition_digest TEXT NOT NULL,
            fence INTEGER NOT NULL CHECK (fence > 0),
            status TEXT NOT NULL CHECK (
              status IN ('running', 'paused', 'failed', 'completed')
            ),
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            UNIQUE (thread_id, namespace, sequence),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (parent_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_checkpoint_history
            ON tamoz_checkpoints(thread_id, namespace, sequence DESC)
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_checkpoint_execution
            ON tamoz_checkpoints(thread_id, namespace, execution_id, sequence DESC)
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_pending_activations (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            base_checkpoint_id TEXT NOT NULL,
            node TEXT NOT NULL,
            path BLOB NOT NULL,
            outcome_digest TEXT NOT NULL,
            consumed_by TEXT,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace, execution_id, task_id),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (base_checkpoint_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
            FOREIGN KEY (consumed_by) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_pending_writes (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            write_index INTEGER NOT NULL CHECK (write_index >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('channel', 'routes')),
            channel TEXT,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            PRIMARY KEY (
              thread_id, namespace, execution_id, task_id, write_index
            ),
            FOREIGN KEY (thread_id, namespace, execution_id, task_id)
              REFERENCES tamoz_pending_activations(
                thread_id, namespace, execution_id, task_id
              )
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_requests (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            request_id TEXT NOT NULL,
            enqueue_sequence INTEGER NOT NULL CHECK (enqueue_sequence >= 0),
            input_digest TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (
              operation IN ('turn', 'resume', 'retry', 'continue', 'fork', 'redirect')
            ),
            delivery_mode TEXT NOT NULL CHECK (
              delivery_mode IN ('queue', 'redirect')
            ),
            status TEXT NOT NULL CHECK (
              status IN (
                'queued', 'claimed', 'running', 'redirecting', 'completed', 'failed'
              )
            ),
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            execution_id TEXT,
            target_execution_id TEXT,
            cancellation_generation INTEGER,
            owner_fence INTEGER,
            checkpoint_id TEXT,
            response BLOB,
            response_digest TEXT,
            terminal_error BLOB,
            terminal_error_digest TEXT,
            retryable INTEGER CHECK (retryable IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (thread_id, namespace, request_id),
            UNIQUE (thread_id, namespace, enqueue_sequence),
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE,
            FOREIGN KEY (checkpoint_id) REFERENCES tamoz_checkpoints(id)
              ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_request_queue
            ON tamoz_requests(thread_id, namespace, enqueue_sequence)
            WHERE status NOT IN ('completed', 'failed')
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_request_transitions (
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            request_id TEXT NOT NULL,
            transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
            from_status TEXT,
            to_status TEXT NOT NULL,
            fence INTEGER,
            evidence BLOB,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (
              thread_id, namespace, request_id, transition_index
            ),
            FOREIGN KEY (thread_id, namespace, request_id)
              REFERENCES tamoz_requests(thread_id, namespace, request_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effects (
            effect_key TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            execution_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            call_index INTEGER NOT NULL CHECK (call_index >= 0),
            operation TEXT NOT NULL,
            safety TEXT NOT NULL CHECK (
              safety IN (
                'read_only', 'idempotent', 'transactional', 'reconcilable', 'unsafe'
              )
            ),
            request_digest TEXT NOT NULL,
            status TEXT NOT NULL CHECK (
              status IN (
                'prepared', 'running', 'succeeded', 'failed', 'unknown',
                'reconcile', 'abandoned'
              )
            ),
            current_attempt INTEGER CHECK (current_attempt > 0),
            requires_reconciliation INTEGER NOT NULL DEFAULT 0
              CHECK (requires_reconciliation IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            FOREIGN KEY (thread_id, namespace)
              REFERENCES tamoz_namespaces(thread_id, namespace)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_effect_execution
            ON tamoz_effects(thread_id, namespace, execution_id)
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effect_attempts (
            effect_key TEXT NOT NULL,
            attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
            attempt_token TEXT NOT NULL UNIQUE,
            fence INTEGER NOT NULL CHECK (fence > 0),
            status TEXT NOT NULL CHECK (
              status IN (
                'prepared', 'running', 'succeeded', 'failed', 'unknown', 'abandoned'
              )
            ),
            deadline_ms INTEGER NOT NULL,
            result BLOB,
            result_digest TEXT,
            external_id TEXT,
            error BLOB,
            error_digest TEXT,
            prepared_at_ms INTEGER NOT NULL,
            started_at_ms INTEGER,
            completed_at_ms INTEGER,
            PRIMARY KEY (effect_key, attempt_number),
            FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_effect_transitions (
            effect_key TEXT NOT NULL,
            transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
            transition TEXT NOT NULL,
            attempt_number INTEGER,
            actor TEXT,
            evidence BLOB,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (effect_key, transition_index),
            FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_store_heads (
            namespace TEXT NOT NULL,
            key TEXT NOT NULL,
            current_version INTEGER NOT NULL CHECK (current_version > 0),
            deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
            sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (namespace, key)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_store_versions (
            namespace TEXT NOT NULL,
            key TEXT NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
            sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
            format_version INTEGER NOT NULL CHECK (format_version > 0),
            payload BLOB,
            payload_digest TEXT,
            created_at_ms INTEGER NOT NULL,
            PRIMARY KEY (namespace, key, version)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_thread_tombstones (
            thread_id TEXT PRIMARY KEY,
            tombstone_id TEXT NOT NULL UNIQUE,
            expected_tips BLOB NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active', 'purged')),
            effect_policy TEXT NOT NULL,
            authorization BLOB NOT NULL,
            report BLOB NOT NULL,
            report_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            purge_after_ms INTEGER,
            FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
              ON DELETE CASCADE
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_deletion_receipts (
            tombstone_id TEXT PRIMARY KEY,
            thread_id_digest TEXT NOT NULL,
            report BLOB NOT NULL,
            report_digest TEXT NOT NULL,
            purged_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
      ].freeze

      MIGRATION_1_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_1.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # P11 (three-layer memory) §2/§4 P11-B: the lexical memory index. One
      # row per Store version of a memory record, written in the SAME
      # transaction as the Store version/head append (DC-3) by
      # `Tamoz::SQLite::MemoryRepository`. The retrieval query filters on the
      # scope/state/sensitivity/validity/compatibility columns BEFORE any row
      # is materialized or decrypted (invariant 30); `statement_search` is
      # populated only for non-sensitive records, so a sensitive statement
      # never enters a searchable column (invariant 24).
      MIGRATION_2 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_memory_index (
            store_namespace TEXT NOT NULL,
            memory_id TEXT NOT NULL,
            record_version INTEGER NOT NULL CHECK (record_version > 0),
            layer TEXT NOT NULL,
            class TEXT NOT NULL,
            state TEXT NOT NULL,
            scopes_tenant TEXT NOT NULL,
            scopes_user TEXT NOT NULL,
            scopes_project TEXT NOT NULL,
            sensitivity TEXT NOT NULL CHECK (
              sensitivity IN ('public', 'internal', 'sensitive')
            ),
            valid_until_ms INTEGER,
            compatibility_graph TEXT NOT NULL,
            compatibility_behavior TEXT NOT NULL,
            statement_search TEXT,
            searchable INTEGER NOT NULL CHECK (searchable IN (0, 1)),
            PRIMARY KEY (store_namespace, memory_id, record_version)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_memory_index_scope
            ON tamoz_memory_index(
              store_namespace, state, scopes_tenant, scopes_user, scopes_project
            )
        SQL
      ].freeze

      MIGRATION_2_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_2.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # P13 (durable scheduling) §10: the scheduler tables. `tamoz_schedules`
      # stores one row per schedule revision (CAS on expected_revision);
      # `tamoz_occurrences` stores the closed state machine (due → claimed →
      # enqueued → running → succeeded|failed|cancelled|unknown, plus
      # skipped|coalesced) with the durable fence/owner and a
      # `request_id` UNIQUE constraint that is the dedup seam: a retried
      # delivery re-enqueues the SAME request row, and a byte-different
      # duplicate raises `CheckpointConflictError`. The occurrence references
      # the request inbox by request id only — no FK into the request tables,
      # so a pre-P13 database migrates forward without touching existing rows.
      MIGRATION_3 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_schedules (
            schedule_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision > 0),
            definition_digest TEXT NOT NULL,
            payload TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (schedule_id, revision)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_occurrences (
            occurrence_id TEXT NOT NULL,
            schedule_id TEXT NOT NULL,
            schedule_revision INTEGER NOT NULL CHECK (schedule_revision > 0),
            nominal_fire_at_utc INTEGER NOT NULL,
            not_before INTEGER NOT NULL,
            request_id TEXT NOT NULL UNIQUE,
            state TEXT NOT NULL CHECK (
              state IN ('due', 'claimed', 'enqueued', 'running', 'succeeded',
                        'failed', 'cancelled', 'unknown', 'skipped', 'coalesced')
            ),
            fence INTEGER,
            owner TEXT,
            reason TEXT,
            payload_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (occurrence_id)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_occurrences_due
            ON tamoz_occurrences(schedule_id, state, not_before)
        SQL
      ].freeze

      MIGRATION_3_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_3.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # P14 (streaming input) §11/C8: the stream tables.
      # `tamoz_stream_channels` stores the content-addressed ChannelDescriptor
      # revisions; `tamoz_stream_events` the admitted event log keyed by the
      # scoped identity (admitted/duplicate/quarantined/rejected outcomes);
      # `tamoz_stream_partitions` the checkpoint/watermark per partition.
      # Admission metadata and the payload hash are stored; old bytes are
      # never re-decoded under a new scheme (design §5).
      MIGRATION_4 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_channels (
            channel_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision > 0),
            definition_digest TEXT NOT NULL,
            payload TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (channel_id, revision)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_events (
            identity TEXT NOT NULL PRIMARY KEY,
            event_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            schema_id TEXT NOT NULL,
            schema_version INTEGER NOT NULL,
            payload_hash TEXT NOT NULL,
            tenant_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            channel_revision INTEGER NOT NULL,
            partition_key TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            event_time INTEGER NOT NULL,
            observed_time INTEGER NOT NULL,
            ingestion_time INTEGER NOT NULL,
            sequence INTEGER,
            outcome TEXT NOT NULL CHECK (
              outcome IN ('admitted', 'duplicate', 'quarantined', 'rejected')
            ),
            reason TEXT,
            payload TEXT NOT NULL,
            processing_time INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_partitions (
            partition_key TEXT NOT NULL PRIMARY KEY,
            watermark INTEGER NOT NULL,
            last_processing_time INTEGER NOT NULL,
            idleness_at INTEGER,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_stream_events_channel
            ON tamoz_stream_events(channel_id, event_time)
        SQL
      ].freeze

      MIGRATION_4_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_4.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # P14-B (design §8, plan §5/C3): the processing-plane tables.
      # `tamoz_stream_operator_state` holds bounded per-partition operator
      # state (windows/reducers/timers); `tamoz_stream_situations` the
      # immutable Situation versions with a current-projection pointer;
      # `tamoz_stream_triggers` the persisted trigger evaluations and
      # cognition-admission outcomes; `tamoz_stream_outbox` the bridge work
      # drained into the ordinary request inbox OUTSIDE the processing
      # transaction (C3). All timestamps are stream-owned (injected clock),
      # never backend_time.
      MIGRATION_5 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_operator_state (
            partition_key TEXT NOT NULL,
            spec_digest TEXT NOT NULL,
            state TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (partition_key)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_situations (
            situation_id TEXT NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            spec_digest TEXT NOT NULL,
            phase TEXT NOT NULL,
            facts TEXT NOT NULL,
            hypotheses TEXT NOT NULL,
            confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
            evidence TEXT NOT NULL,
            completeness TEXT NOT NULL CHECK (
              completeness IN ('provisional', 'on_time', 'corrected', 'final_by_policy', 'uncertain')
            ),
            source_versions TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (situation_id, version)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_situation_current (
            situation_id TEXT NOT NULL PRIMARY KEY,
            current_version INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_triggers (
            trigger_id TEXT NOT NULL PRIMARY KEY,
            partition_key TEXT NOT NULL,
            situation_id TEXT NOT NULL,
            scores TEXT NOT NULL,
            evidence TEXT NOT NULL,
            reasons TEXT NOT NULL,
            completeness TEXT NOT NULL,
            cost_estimate INTEGER NOT NULL,
            freshness INTEGER NOT NULL,
            deadline INTEGER,
            outcome TEXT NOT NULL CHECK (
              outcome IN ('ignored', 'debounced', 'coalesced', 'deferred',
                          'admitted', 'superseded', 'expired', 'rejected')
            ),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_outbox (
            outbox_id TEXT NOT NULL PRIMARY KEY,
            partition_key TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            drained INTEGER NOT NULL DEFAULT 0 CHECK (drained IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_stream_situations_current
            ON tamoz_stream_situations(situation_id, version DESC)
        SQL
      ].freeze

      MIGRATION_5_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_5.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # Comm channels (COMMS_DESIGN §13): the CommsStore tables for one shared
      # runtime database. Surface descriptors and revisions, versioned
      # correspondent bindings, hashed pairing challenges, conversation routes,
      # the inbound disposition ledger (never raw update JSON), per-request
      # reservation/projection state, the fenced poller lease, the bounded
      # delivery outbox (journaled through tamoz_effects, never duplicating
      # attempts or receipts), single-use approval prompts, the exact decision
      # records (transactional with prompt consumption, design §9/§13), and the
      # bounded control-output gap ledger.
      #
      # Times are millisecond integers bound by the caller's clock so every
      # primitive is deterministic under an injected clock and kill-consistent.
      MIGRATION_6 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_surfaces (
            surface_id TEXT NOT NULL PRIMARY KEY,
            revision INTEGER NOT NULL CHECK (revision > 0),
            definition_digest TEXT NOT NULL,
            descriptor_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_bindings (
            surface_id TEXT NOT NULL,
            correspondent_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
            bound_by TEXT NOT NULL,
            bound_at_ms INTEGER NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            revocation_reason TEXT,
            PRIMARY KEY (surface_id, correspondent_id, version)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_pairing_challenges (
            challenge_digest TEXT NOT NULL PRIMARY KEY,
            surface_id TEXT NOT NULL,
            correspondent_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'consumed')),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
            expires_at_ms INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_conversations (
            surface_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
            thread_id TEXT NOT NULL,
            profile_id TEXT NOT NULL,
            threading TEXT NOT NULL CHECK (threading IN ('conversation', 'per_message')),
            bound_at_ms INTEGER NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            PRIMARY KEY (surface_id, conversation_id)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_inbound (
            surface_id TEXT NOT NULL,
            surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
            bot_id INTEGER NOT NULL CHECK (bot_id >= 0),
            update_id INTEGER NOT NULL CHECK (update_id >= 0),
            raw_payload_hash TEXT NOT NULL,
            parser_version INTEGER NOT NULL CHECK (parser_version > 0),
            kind TEXT NOT NULL CHECK (
              kind IN ('text', 'command', 'callback', 'membership', 'unsupported')
            ),
            correspondent_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            disposition TEXT NOT NULL CHECK (
              disposition IN ('request', 'decision', 'ignored', 'rejected', 'quarantined')
            ),
            reason TEXT NOT NULL,
            request_id TEXT,
            decision_id TEXT,
            observed_at_ms INTEGER NOT NULL,
            ingested_at_ms INTEGER NOT NULL,
            PRIMARY KEY (surface_id, bot_id, update_id)
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_requests (
            request_id TEXT NOT NULL PRIMARY KEY,
            surface_id TEXT NOT NULL,
            surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
            conversation_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            profile_id TEXT NOT NULL,
            reservation INTEGER NOT NULL CHECK (reservation > 0),
            projection_state TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_poll_state (
            bot_id INTEGER NOT NULL PRIMARY KEY CHECK (bot_id >= 0),
            surface_id TEXT NOT NULL,
            next_offset INTEGER CHECK (next_offset IS NULL OR next_offset >= 0),
            poller_owner_id TEXT,
            poller_fence INTEGER CHECK (poller_fence IS NULL OR poller_fence > 0),
            poller_expires_at_ms INTEGER,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_outbox (
            delivery_id TEXT NOT NULL PRIMARY KEY,
            surface_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (
              kind IN ('accepted', 'answer', 'approval_request', 'failed',
                       'stopped', 'blocked', 'control')
            ),
            operation TEXT NOT NULL CHECK (operation IN ('send_message', 'edit_message')),
            text TEXT NOT NULL,
            part_index INTEGER NOT NULL CHECK (part_index >= 0),
            part_count INTEGER NOT NULL CHECK (part_count > 0),
            markup TEXT,
            journaled INTEGER NOT NULL CHECK (journaled IN (0, 1)),
            content_digest TEXT NOT NULL,
            render_version INTEGER NOT NULL CHECK (render_version > 0),
            expires_at_ms INTEGER,
            status TEXT NOT NULL CHECK (
              status IN ('pending', 'claimed', 'succeeded', 'failed', 'unknown')
            ),
            claim_owner TEXT,
            claim_fence INTEGER CHECK (claim_fence IS NULL OR claim_fence > 0),
            claim_expires_at_ms INTEGER,
            effect_key TEXT,
            effect_execution_id TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_approval_prompts (
            reference_digest TEXT NOT NULL PRIMARY KEY,
            surface_id TEXT,
            surface_revision INTEGER CHECK (surface_revision IS NULL OR surface_revision > 0),
            thread_id TEXT NOT NULL,
            occurrence_id TEXT NOT NULL,
            interrupt_digest TEXT NOT NULL,
            correspondent_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            prompt_receipt TEXT,
            status TEXT NOT NULL CHECK (status IN ('inactive', 'active', 'consumed')),
            created_at_ms INTEGER NOT NULL,
            activated_at_ms INTEGER,
            consumed_at_ms INTEGER,
            expires_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_decisions (
            decision_id TEXT NOT NULL PRIMARY KEY,
            thread_id TEXT NOT NULL,
            occurrence_id TEXT NOT NULL,
            interrupt_digest TEXT NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('approve', 'deny')),
            actor_kind TEXT NOT NULL CHECK (actor_kind IN ('os_user', 'telegram_user')),
            actor_id TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('cli', 'telegram')),
            decided_at_ms INTEGER NOT NULL,
            expires_at_ms INTEGER NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'claimed', 'consumed')),
            claim_owner TEXT,
            claim_fence INTEGER CHECK (claim_fence IS NULL OR claim_fence > 0),
            claim_expires_at_ms INTEGER,
            consumed_at_ms INTEGER
          ) STRICT
        SQL
        <<~SQL.freeze,
          CREATE TABLE tamoz_comms_gaps (
            gap_id TEXT NOT NULL PRIMARY KEY,
            surface_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (
              kind IN ('expired_control', 'coalesced_control', 'capacity_refused')
            ),
            reason TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
          ) STRICT
        SQL
      ].freeze

      MIGRATION_6_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_6.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # Comms (COMMS_DESIGN §10): 6 -> 7 — the outbox gains its transport
      # receipt column. Receipts (message_id, platform date) are recorded on
      # a durable success and are what make a send provably delivered.
      MIGRATION_7 = [
        <<~SQL.freeze
          ALTER TABLE tamoz_comms_outbox ADD COLUMN receipt TEXT
        SQL
      ].freeze

      MIGRATION_7_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_7.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # Delivery scheduling (COMMS_DESIGN §10): durable next-allowed times
      # make rate limits survive a drainer restart and serialize competing
      # drainers without a process-local lock.
      MIGRATION_8 = [
        <<~SQL.freeze,
          ALTER TABLE tamoz_comms_outbox ADD COLUMN send_started_at_ms INTEGER
        SQL
        <<~SQL.freeze
          CREATE TABLE tamoz_comms_delivery_pacing (
            surface_id TEXT NOT NULL,
            scope TEXT NOT NULL,
            next_allowed_at_ms INTEGER NOT NULL CHECK (next_allowed_at_ms >= 0),
            PRIMARY KEY (surface_id, scope)
          ) STRICT
        SQL
      ].freeze

      MIGRATION_8_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_8.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # ADR-049 (PLAN_ADR049 Phase 2): the approval prompt pins the evidence
      # an approver must present (INV-C). The column is nullable only because
      # SQLite cannot ALTER-ADD a NOT NULL column; every prompt row written
      # carries the pinned value.
      MIGRATION_9 = [
        <<~SQL.freeze
          ALTER TABLE tamoz_comms_approval_prompts ADD COLUMN required_evidence TEXT
        SQL
      ].freeze

      MIGRATION_9_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_9.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # ADR-049 (PLAN_ADR049 Phase 4): the decision audit records the evidence
      # level that made an approve legal and why (contract §7.1).
      MIGRATION_10 = [
        <<~SQL.freeze,
          ALTER TABLE tamoz_comms_decisions ADD COLUMN evidence TEXT
        SQL
        <<~SQL.freeze,
          ALTER TABLE tamoz_comms_decisions ADD COLUMN reason TEXT
        SQL
      ].freeze

      MIGRATION_10_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_10.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # JCS digest-rule cutover (PLAN_TAMOZ_STREAM_BUILD T0.1, CONTRACTS §13):
      # the canonical rule moved to RFC 8785 (`Tamoz::Core.jcs`), so digests
      # that embedded the old canonical-JSON serialization are re-sealed.
      #
      # The stream-engine tables (MIGRATION_4/5) carried canonical-JSON digests
      # that could differ under JCS (their situations may contain floats);
      # clearing them here ACCEPTS the loss of undrained outbox items and
      # resets the per-partition watermarks. MIGRATION_13 then DROPS those
      # tables outright — the P14 engine is retired (T8.3). Circuit rows are
      # keyed by the old canonical scope digest and are re-keyed on first use,
      # so they are cleared too. Scheduler/occurrence and comms identities
      # were NOT migrated to the JCS rule (they never cross the product
      # boundary), so their stored rows stay valid because their derivation is
      # unchanged.
      # Checkpoints are the deliberate exception to the clears: they are kept
      # so resume stops typed at the graph-identity guard rather than silently
      # reinterpreting digests sealed under a different rule. The epoch row
      # records this cutover for any future digest-rule change.
      MIGRATION_11 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_digest_epoch (
            epoch INTEGER NOT NULL CHECK (epoch > 0)
          ) STRICT
        SQL
        <<~SQL.freeze,
          INSERT INTO tamoz_digest_epoch (epoch) VALUES (1)
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_channels
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_events
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_partitions
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_operator_state
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_situations
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_situation_current
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_triggers
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_stream_outbox
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_store_versions WHERE namespace GLOB 'tamoz.circuit.*'
        SQL
        <<~SQL.freeze,
          DELETE FROM tamoz_store_heads WHERE namespace GLOB 'tamoz.circuit.*'
        SQL
      ].freeze

      MIGRATION_11_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_11.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # Situation-scoped memory (PLAN_TAMOZ_STREAM_BUILD T0.3, §5.6): the
      # memory index gains the situation/entity dimension so an episode's
      # Experience can be scoped to (situation_type, entity_type, entity_id).
      # The table rebuild (SQLite cannot ADD a CHECK) enforces the all-or-none
      # invariant at the schema level: a row is either fully situation-scoped
      # or fully ordinary. Rows written before this migration carry NULL
      # situation scopes, which the retrieval boundary keeps outside the
      # situation dimension.
      MIGRATION_12 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_memory_index_new (
            store_namespace TEXT NOT NULL,
            memory_id TEXT NOT NULL,
            record_version INTEGER NOT NULL CHECK (record_version > 0),
            layer TEXT NOT NULL,
            class TEXT NOT NULL,
            state TEXT NOT NULL,
            scopes_tenant TEXT NOT NULL,
            scopes_user TEXT NOT NULL,
            scopes_project TEXT NOT NULL,
            sensitivity TEXT NOT NULL CHECK (
              sensitivity IN ('public', 'internal', 'sensitive')
            ),
            valid_until_ms INTEGER,
            compatibility_graph TEXT NOT NULL,
            compatibility_behavior TEXT NOT NULL,
            statement_search TEXT,
            searchable INTEGER NOT NULL CHECK (searchable IN (0, 1)),
            scopes_situation_type TEXT,
            scopes_entity_type TEXT,
            scopes_entity_id TEXT,
            PRIMARY KEY (store_namespace, memory_id, record_version),
            CHECK (
              (scopes_situation_type IS NULL AND scopes_entity_type IS NULL AND scopes_entity_id IS NULL)
              OR
              (scopes_situation_type IS NOT NULL AND scopes_entity_type IS NOT NULL AND scopes_entity_id IS NOT NULL)
            )
          ) STRICT
        SQL
        <<~SQL.freeze,
          INSERT INTO tamoz_memory_index_new(
            store_namespace, memory_id, record_version, layer, class, state,
            scopes_tenant, scopes_user, scopes_project, sensitivity,
            valid_until_ms, compatibility_graph, compatibility_behavior,
            statement_search, searchable,
            scopes_situation_type, scopes_entity_type, scopes_entity_id
          )
          SELECT store_namespace, memory_id, record_version, layer, class, state,
                 scopes_tenant, scopes_user, scopes_project, sensitivity,
                 valid_until_ms, compatibility_graph, compatibility_behavior,
                 statement_search, searchable,
                 NULL, NULL, NULL
          FROM tamoz_memory_index
        SQL
        <<~SQL.freeze,
          DROP TABLE tamoz_memory_index
        SQL
        <<~SQL.freeze,
          ALTER TABLE tamoz_memory_index_new RENAME TO tamoz_memory_index
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_memory_index_scope
            ON tamoz_memory_index(
              store_namespace, state, scopes_tenant, scopes_user, scopes_project
            )
        SQL
        <<~SQL.freeze,
          CREATE INDEX idx_tamoz_memory_index_situation
            ON tamoz_memory_index(store_namespace, state, scopes_entity_type, scopes_tenant)
        SQL
      ].freeze

      MIGRATION_12_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_12.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # T8.3 (PLAN_TAMOZ_STREAM_BUILD T8.3): the old P14 streaming engine is
      # retired by forward migration — no backward compatibility (owner
      # convention). MIGRATION_4/5's stream tables are dropped outright; the
      # supervised episode worker keeps nothing of the old engine's durable
      # state. MIGRATION_11 already cleared the rows; this migration removes
      # the tables so a fresh schema carries no trace of the old engine.
      MIGRATION_13 = %w[
        tamoz_stream_outbox
        tamoz_stream_triggers
        tamoz_stream_situation_current
        tamoz_stream_situations
        tamoz_stream_operator_state
        tamoz_stream_partitions
        tamoz_stream_events
        tamoz_stream_channels
      ].map { |table| "DROP TABLE IF EXISTS #{table}" }.freeze

      MIGRATION_13_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_13.join("\n-- tamoz migration boundary --\n")
      ).freeze

      MIGRATION_14 = [
        <<~SQL.freeze,
          CREATE TABLE tamoz_stream_verifications (
            tenant_id TEXT NOT NULL CHECK (length(tenant_id) > 0),
            intent_id TEXT NOT NULL,
            command_id TEXT,
            decision_id TEXT NOT NULL,
            episode_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            decision_digest TEXT NOT NULL CHECK (
              substr(decision_digest, 1, 7) = 'sha256:' AND
              length(decision_digest) = 71 AND
              substr(decision_digest, 8) NOT GLOB '*[^0-9a-f]*'
            ),
            episode TEXT NOT NULL CHECK (json_valid(episode) = 1),
            state TEXT NOT NULL CHECK (state IN ('awaiting', 'observed', 'reconciled')),
            outcome_id TEXT,
            outcome_digest TEXT CHECK (
              outcome_digest IS NULL OR (
                substr(outcome_digest, 1, 7) = 'sha256:' AND
                length(outcome_digest) = 71 AND
                substr(outcome_digest, 8) NOT GLOB '*[^0-9a-f]*'
              )
            ),
            verdict TEXT CHECK (
              verdict IS NULL OR verdict IN (
                'verified', 'refuted', 'inconclusive',
                'superseded_before_verification'
              )
            ),
            reconciliation_version INTEGER CHECK (
              reconciliation_version IS NULL OR reconciliation_version > 0
            ),
            source_authority TEXT,
            opened_at INTEGER NOT NULL CHECK (opened_at >= 0),
            reconciled_at INTEGER CHECK (reconciled_at IS NULL OR reconciled_at >= opened_at),
            learnable INTEGER NOT NULL DEFAULT 0 CHECK (learnable IN (0, 1)),
            CHECK (
              (state = 'awaiting' AND outcome_id IS NULL AND outcome_digest IS NULL AND
               verdict IS NULL AND reconciliation_version IS NULL AND
               source_authority IS NULL AND reconciled_at IS NULL AND learnable = 0)
              OR
              (state = 'observed' AND outcome_id IS NOT NULL AND outcome_digest IS NOT NULL AND
               command_id IS NOT NULL AND verdict IS NULL AND reconciliation_version IS NULL AND
               source_authority IS NULL AND reconciled_at IS NULL AND learnable = 0)
              OR
              (state = 'reconciled' AND command_id IS NOT NULL AND outcome_id IS NOT NULL AND
               outcome_digest IS NOT NULL AND verdict IS NOT NULL AND
               reconciliation_version IS NOT NULL AND source_authority IS NOT NULL AND
               reconciled_at IS NOT NULL AND
               (learnable = 0 OR (verdict IN ('verified', 'refuted') AND outcome_id IS NOT NULL)))
            ),
            PRIMARY KEY (tenant_id, intent_id)
          ) STRICT
        SQL
        <<~SQL.freeze
          CREATE INDEX idx_tamoz_stream_verifications_state
            ON tamoz_stream_verifications(state, opened_at, tenant_id, intent_id)
        SQL
      ].freeze

      MIGRATION_14_CHECKSUM = Digest::SHA256.hexdigest(
        MIGRATION_14.join("\n-- tamoz migration boundary --\n")
      ).freeze

      # Ordinal -> [statements, checksum]. The monotonic-ordering test asserts
      # the ordinals are exactly 1..CURRENT_VERSION with no gap and no reuse.
      MIGRATIONS = {
        1 => [MIGRATION_1, MIGRATION_1_CHECKSUM],
        2 => [MIGRATION_2, MIGRATION_2_CHECKSUM],
        3 => [MIGRATION_3, MIGRATION_3_CHECKSUM],
        4 => [MIGRATION_4, MIGRATION_4_CHECKSUM],
        5 => [MIGRATION_5, MIGRATION_5_CHECKSUM],
        6 => [MIGRATION_6, MIGRATION_6_CHECKSUM],
        7 => [MIGRATION_7, MIGRATION_7_CHECKSUM],
        8 => [MIGRATION_8, MIGRATION_8_CHECKSUM],
        9 => [MIGRATION_9, MIGRATION_9_CHECKSUM],
        10 => [MIGRATION_10, MIGRATION_10_CHECKSUM],
        11 => [MIGRATION_11, MIGRATION_11_CHECKSUM],
        12 => [MIGRATION_12, MIGRATION_12_CHECKSUM],
        13 => [MIGRATION_13, MIGRATION_13_CHECKSUM],
        14 => [MIGRATION_14, MIGRATION_14_CHECKSUM]
      }.freeze

      attr_reader :path, :limits, :fault_injector

      def self.verify_connection!(connection)
        application_id = connection.get_first_value("PRAGMA application_id")
        version = connection.get_first_value("PRAGMA user_version")
        unless application_id == APPLICATION_ID
          raise MigrationError, "SQLite application id is missing or invalid"
        end
        unless version == CURRENT_VERSION
          raise MigrationError, "SQLite schema version is invalid"
        end
        epoch = connection.get_first_value("SELECT epoch FROM tamoz_digest_epoch")
        unless epoch == DIGEST_EPOCH
          raise MigrationError, "SQLite digest epoch is invalid"
        end
        (1..CURRENT_VERSION).each do |ordinal|
          verify_migration_row!(connection, ordinal)
        end

        version
      rescue ::SQLite3::Exception => error
        ExceptionMapper.raise_mapped(error, operation: "schema verification")
      end

      # A later phase cannot reuse an ordinal already consumed by an earlier
      # migration: the migration set must be exactly the contiguous range
      # 1..CURRENT_VERSION, and every ordinal's checksum is registered.
      def self.migration_ordinals
        (1..CURRENT_VERSION).to_a
      end

      def initialize(path:, limits:, fault_injector:)
        @path = String(path).dup.freeze
        @limits = limits
        @fault_injector = fault_injector
      end

      def migrate!
        connection = ConnectionPool.open(path, limits:, initialize_wal: true)
        application_id = connection.get_first_value("PRAGMA application_id")
        version = connection.get_first_value("PRAGMA user_version")
        if application_id != 0 && application_id != APPLICATION_ID
          raise MigrationError, "SQLite application id belongs to another application"
        end
        if version > CURRENT_VERSION
          raise MigrationError,
                "SQLite schema version #{version} is newer than #{CURRENT_VERSION}"
        end

        bring_forward(connection, application_id:, version:)
        true
      rescue ::SQLite3::Exception => error
        ExceptionMapper.raise_mapped(error, operation: "schema migration")
      ensure
        connection&.close unless connection&.closed?
      end

      private

      # One rule for every version below the current one, rather than a branch
      # per ordinal. The old `when 0` / `when 1` pair meant versions 2, 3 and 4
      # fell through to `verify_connection!` — which demands `version ==
      # CURRENT_VERSION` — so a database created at any of them could never
      # migrate forward; it raised `MigrationError` on every open instead.
      #
      # The invariant an in-place upgrade needs is that everything already
      # applied is intact: each ordinal up to `version` must still be recorded
      # with its registered checksum before pending ones are layered on top.
      def bring_forward(connection, application_id:, version:)
        return self.class.verify_connection!(connection) if version == CURRENT_VERSION

        (1..version).each { |ordinal| self.class.verify_migration_row!(connection, ordinal) }
        apply_migrations(connection, from: version,
                                     set_application_id: application_id != APPLICATION_ID)
      end

      # All pending migrations (from + 1 .. CURRENT_VERSION) apply in ONE
      # transaction: a failure rolls back every statement, so a fresh database
      # and an in-place 1 -> 2 upgrade are both all-or-nothing. Each ordinal
      # runs under its own Transaction label (`migration.1`, `migration.2`) so
      # fault injection can target a specific migration's statements while the
      # outer rollback stays atomic across them all.
      def apply_migrations(connection, from:, set_application_id:)
        connection.execute("BEGIN EXCLUSIVE")
        begin
          transaction = nil
          (from + 1..CURRENT_VERSION).each do |ordinal|
            statements, checksum = MIGRATIONS.fetch(ordinal)
            transaction = Transaction.new(
              connection:,
              operation: "migration.#{ordinal}",
              attempt: 1,
              fault_injector:
            )
            statements.each_with_index do |sql, index|
              transaction.execute("migration.#{ordinal}.#{index + 1}", sql)
            end
            now = transaction.scalar("migration.#{ordinal}.time", backend_time_sql)
            transaction.execute(
              "migration.#{ordinal}.record",
              <<~SQL,
                INSERT INTO tamoz_schema_migrations(version, checksum, applied_at_ms)
                VALUES (?, ?, ?)
              SQL
              [ordinal, checksum, now]
            )
          end
          if set_application_id
            transaction.execute(
              "migration.application_id",
              "PRAGMA application_id = #{APPLICATION_ID}"
            )
          end
          transaction.execute(
            "migration.user_version",
            "PRAGMA user_version = #{CURRENT_VERSION}"
          )
          connection.execute("COMMIT")
        rescue Exception # rubocop:disable Lint/RescueException
          connection.execute("ROLLBACK") if connection.transaction_active?
          raise
        end
      end

      def self.verify_migration_row!(connection, ordinal)
        statements, checksum = MIGRATIONS.fetch(ordinal)
        row = connection.get_first_row(
          "SELECT checksum FROM tamoz_schema_migrations WHERE version = ?",
          [ordinal]
        )
        unless row && row.fetch(0) == checksum
          raise MigrationError,
                "SQLite migration #{ordinal} checksum is invalid " \
                "(#{statements.length} statements)"
        end
      end

      def backend_time_sql
        sql = <<~SQL
          SELECT (
            CAST(strftime('%s', 'now') AS INTEGER) * 1000 +
            CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER)
          )
        SQL
        sql.lines.map(&:strip).join(" ")
      end

      private_constant :APPLICATION_ID, :MIGRATION_1,
                       :MIGRATION_1_CHECKSUM, :MIGRATION_2, :MIGRATION_2_CHECKSUM,
                       :MIGRATION_3, :MIGRATION_3_CHECKSUM,
                       :MIGRATION_4, :MIGRATION_4_CHECKSUM,
                       :MIGRATION_5, :MIGRATION_5_CHECKSUM,
                       :MIGRATION_6, :MIGRATION_6_CHECKSUM,
                       :MIGRATION_7, :MIGRATION_7_CHECKSUM,
                       :MIGRATION_8, :MIGRATION_8_CHECKSUM,
                       :MIGRATION_9, :MIGRATION_9_CHECKSUM,
                       :MIGRATION_10, :MIGRATION_10_CHECKSUM,
                       :MIGRATION_11, :MIGRATION_11_CHECKSUM,
                       :MIGRATION_12, :MIGRATION_12_CHECKSUM,
                       :MIGRATION_13, :MIGRATION_13_CHECKSUM,
                       :MIGRATION_14, :MIGRATION_14_CHECKSUM, :MIGRATIONS
    end
  end
end
