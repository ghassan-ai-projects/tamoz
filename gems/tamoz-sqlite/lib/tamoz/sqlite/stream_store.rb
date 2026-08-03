# frozen_string_literal: true

require "json"

module Tamoz
  module SQLite
    # P14-A (plan §4, design §5/§6/§15) — the durable StreamStore over SQLite.
    #
    # Admission (invariant 45): the scoped identity is the primary key. A
    # repeated identity with the SAME canonical payload hash is an idempotent
    # duplicate; the SAME identity with a DIFFERENT hash is a quarantine
    # conflict (never overwritten, never silently dropped). Invalid data is a
    # durable rejection. All outcomes are durable rows — never raised, never
    # silent (design §5).
    #
    # Timestamps: every processing-time column comes from the injected
    # StreamClock, never `backend_time`/wall time (plan §5/C1) — so replay
    # re-executes the identical admission chain under the same virtual clock
    # and produces byte-identical rows.
    class StreamStore
      include Tamoz::Stream::StreamStore

      def initialize(adapter:)
        @adapter = adapter
      end

      attr_reader :adapter

      # --- channel deployment (P14-D) ---------------------------------------

      # Deploy a content-addressed ChannelDescriptor revision (CAS on
      # expected_revision when given). Idempotent for the same digest.
      def deploy_channel(descriptor, expected_revision: nil)
        now = 0 # stream tables never use wall time; caller passes clock where
        # it matters; deployment is metadata (design §15), time-stamped by the
        # injected clock in process_partition only.
        _ = now
        bytes = JSON.generate(Tamoz::Core.canonical(descriptor.to_h))
        digest = Wire.digest(
          bytes, domain: "tamoz.sqlite.stream_channel"
        )
        @adapter.__send__(:transaction, operation: "stream.channel.put") do |tx|
          current = tx.scalar(
            "stream.channel.revision",
            <<~SQL,
              SELECT revision FROM tamoz_stream_channels
              WHERE channel_id = ? AND deleted = 0
              ORDER BY revision DESC LIMIT 1
            SQL
            [descriptor.channel_id]
          )
          if current && expected_revision && expected_revision != current
            raise Tamoz::Scheduler::StoreConflictError,
                  "channel #{descriptor.channel_id} is at revision #{current}, " \
                  "expected #{expected_revision}"
          end
          # Idempotent: the exact digest already deployed is a no-op.
          existing_digest = tx.scalar(
            "stream.channel.digest",
            <<~SQL,
              SELECT definition_digest FROM tamoz_stream_channels
              WHERE channel_id = ? AND revision = ? AND deleted = 0
            SQL
            [descriptor.channel_id, current]
          )
          next if existing_digest == descriptor.definition_digest

          revision = (current || 0) + 1
          tx.execute(
            "stream.channel.insert",
            <<~SQL,
              INSERT INTO tamoz_stream_channels(
                channel_id, revision, definition_digest, payload,
                payload_digest, deleted, created_at_ms, updated_at_ms
              )
              VALUES (?, ?, ?, ?, ?, 0, 0, 0)
            SQL
            [descriptor.channel_id, revision, descriptor.definition_digest,
             bytes, digest]
          )
        end
        descriptor
      end

      # --- admission (P14-A) -------------------------------------------------

      def admit(envelope, clock:)
        processing = clock.now_processing
        identity = envelope.identity
        @adapter.__send__(:transaction, operation: "stream.event.admit") do |tx|
          existing = tx.first(
            "stream.event.existing",
            <<~SQL,
              SELECT payload_hash, outcome FROM tamoz_stream_events
              WHERE identity = ?
            SQL
            [identity]
          )
          if existing
            if existing.fetch(0) == envelope.payload_hash
              # Idempotent duplicate (invariant 45).
              next {"outcome" => DUPLICATE, "identity" => identity}
            end

            # Same identity, different hash: quarantine conflict. The original
            # row is untouched; the conflict is a durable record.
            tx.execute(
              "stream.event.quarantine",
              <<~SQL,
                UPDATE tamoz_stream_events
                SET outcome = ?, reason = ?, updated_at_ms = ?
                WHERE identity = ? AND payload_hash = ?
              SQL
              [QUARANTINED, "payload hash changed for a reused identity", processing, identity, existing.fetch(0)]
            )
            next({"outcome" => QUARANTINED, "identity" => identity})
          end

          tx.execute(
            "stream.event.insert",
            <<~SQL,
              INSERT INTO tamoz_stream_events(
                identity, event_id, event_type, schema_id, schema_version,
                payload_hash, tenant_id, source_id, channel_id,
                channel_revision, partition_key, entity_id, event_time,
                observed_time, ingestion_time, sequence, outcome, reason,
                payload, processing_time, created_at_ms, updated_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            SQL
            [
              identity, envelope.event_id, envelope.event_type,
              envelope.schema_id, envelope.schema_version,
              envelope.payload_hash, envelope.tenant_id, envelope.source_id,
              envelope.channel_id, envelope.channel_revision,
              envelope.partition_key, envelope.entity_id, envelope.event_time,
              envelope.observed_time, envelope.ingestion_time, envelope.sequence,
              ADMITTED, JSON.generate(envelope.payload), processing,
              processing, processing
            ]
          )
          {"outcome" => ADMITTED, "identity" => identity}
        end
      end

      def admission_record(identity)
        row = @adapter.__send__(:read, operation: "stream.event.record") do |tx|
          tx.first(
            "stream.event.record",
            <<~SQL,
              SELECT outcome, reason, payload_hash, processing_time
              FROM tamoz_stream_events WHERE identity = ?
            SQL
            [identity]
          )
        end
        return nil unless row

        {
          "outcome" => row.fetch(0),
          "reason" => row.fetch(1),
          "payload_hash" => row.fetch(2),
          "processing_time" => row.fetch(3)
        }
      end

      def durable?(identity)
        admission_record(identity) != nil
      end

      # --- partition checkpoint (P14-B base) --------------------------------

      # Advance the partition watermark (monotonic per partition; a regression
      # raises WatermarkRegressionError, design §7).
      def advance_watermark(partition_key, watermark, clock:)
        processing = clock.now_processing
        @adapter.__send__(:transaction, operation: "stream.partition.advance") do |tx|
          current = tx.scalar(
            "stream.partition.watermark",
            <<~SQL,
              SELECT watermark FROM tamoz_stream_partitions
              WHERE partition_key = ?
            SQL
            [partition_key]
          )
          if current && watermark < current
            raise Tamoz::Stream::WatermarkRegressionError,
                  "partition #{partition_key} watermark regressed from #{current} to #{watermark}"
          end

          if current.nil?
            tx.execute(
              "stream.partition.insert",
              <<~SQL,
                INSERT INTO tamoz_stream_partitions(
                  partition_key, watermark, last_processing_time,
                  idleness_at, created_at_ms, updated_at_ms
                )
                VALUES (?, ?, ?, NULL, ?, ?)
              SQL
              [partition_key, watermark, processing, processing, processing]
            )
          else
            tx.execute(
              "stream.partition.update",
              <<~SQL,
                UPDATE tamoz_stream_partitions
                SET watermark = ?, last_processing_time = ?, updated_at_ms = ?
                WHERE partition_key = ?
              SQL
              [watermark, processing, processing, partition_key]
            )
          end
        end
        watermark
      end

      def watermark(partition_key)
        @adapter.__send__(:read, operation: "stream.partition.read") do |tx|
          tx.scalar(
            "stream.partition.read",
            "SELECT watermark FROM tamoz_stream_partitions WHERE partition_key = ?",
            [partition_key]
          )
        end
      end

      # The newest immutable version of a Situation (the current projection
      # pointer), or nil when none exists.
      def current_situation_version(situation_id)
        @adapter.__send__(:read, operation: "stream.situation.current") do |tx|
          tx.scalar(
            "stream.situation.current",
            "SELECT current_version FROM tamoz_stream_situation_current WHERE situation_id = ?",
            [situation_id]
          )
        end
      end

      # The persisted cognition outcomes for a Situation, newest first
      # (the trigger table is read-visible, not write-only).
      def trigger_outcomes(situation_id, limit: 20)
        bound = limit.clamp(1, 100)
        rows = @adapter.__send__(:read, operation: "stream.trigger.list") do |tx|
          tx.rows(
            "stream.trigger.list",
            <<~SQL,
              SELECT outcome, created_at_ms FROM tamoz_stream_triggers
              WHERE situation_id = ? ORDER BY created_at_ms DESC LIMIT ?
            SQL
            [situation_id, bound]
          )
        end
        rows.map { |row| {"outcome" => row.fetch(0), "created_at_ms" => row.fetch(1)} }
      end

      # --- P14-B: the atomic processing boundary (design §8, plan §5/C3) ----

      # `process_partition` is the ONE transaction owning all six steps:
      #
      #   1. admission/dedup of the batch (durable outcomes, never raised);
      #   2. deterministic operators + due timers over the admitted events and
      #      the bounded per-partition operator state;
      #   3. append any immutable Situation version (correction appends, never
      #      rewrites);
      #   4. persist trigger scores and the cognition-admission outcome;
      #   5. append outbox work (drained OUTSIDE this transaction, C3);
      #   6. advance the partition checkpoint/watermark.
      #
      # No model, network, approval, or effector call happens inside this
      # transaction. All stream-owned timestamps come from the injected
      # `clock` — never `backend_time` — so replay re-executes the identical
      # chain under the same virtual clock and produces byte-identical rows.
      #
      # `operators` is a hash of pure, injected callables (deterministic
      # configuration; no scripts/model/I/O per design §9):
      #   :reduce    -> (events, state, clock) -> [new_state, result]
      #   :situation -> (state, result, clock) -> situation_hash | nil
      #   :trigger   -> (situation, clock) -> trigger_hash | nil
      #   :outbox    -> (situation, clock) -> [{kind:, payload:}, ...]
      #
      # @return [Hash] {"admitted" => [...], "situations" => [...],
      #                 "outbox" => [...], "watermark" => Integer}
      def process_partition(partition_key, batch:, clock:, operators:, spec_digest:,
                            cognition_spec: nil)
        processing = clock.now_processing
        result = {
          "admitted" => [],
          "situations" => [],
          "outbox" => [],
          "watermark" => nil
        }
        @adapter.__send__(:transaction, operation: "stream.partition.process") do |tx|
          # Step 1: admission/dedup for the batch.
          admitted_events = []
          batch.each do |envelope|
            outcome = admit_in_tx(envelope, clock:, tx:)
            admitted_events << envelope if outcome == ADMITTED
          end

          # Step 2: deterministic operators over admitted events + state.
          state = load_operator_state(partition_key, tx)
          new_state, operator_result = operators.fetch(:reduce).call(
            admitted_events, state, clock
          )
          save_operator_state(partition_key, spec_digest, new_state, processing, tx)

          # Step 3/4: Situation version + trigger evaluation. The situation
          # operator receives the NEWLY ADMITTED events (a re-run with only
          # duplicates is the same state — no new Situation version).
          situation = operators[:situation]&.call(
            new_state, operator_result, clock, admitted_events
          )
          trigger = nil
          versioned_situation = nil
          if situation
            version = append_situation(partition_key, spec_digest, situation, processing, tx)
            versioned_situation = situation.merge("version" => version)
            trigger = operators[:trigger]&.call(versioned_situation, clock)
            # P14-C integration: when a cognition spec is supplied, the PURE
            # evaluator decides the persisted outcome (the operator's claim is
            # a candidate, not the verdict). The situation_version is injected
            # before evaluation (the evaluator requires it).
            if trigger && cognition_spec
              trigger = trigger.merge("situation_version" => version)
              trigger = trigger.merge(
                "outcome" => Tamoz::Stream::CognitionAdmission.evaluate(
                  trigger:, now: processing, spec: cognition_spec
                ).to_s
              )
            end
            append_trigger(partition_key, situation, trigger, version, processing, tx) if trigger
            result["situations"] << versioned_situation
          end

          # Step 5: outbox work (drained outside the transaction). The outbox
          # sees the VERSIONED situation (the version is part of the immutable
          # identity).
          outbox_items = operators[:outbox]&.call(versioned_situation, clock) || []
          outbox_items.each do |item|
            append_outbox(partition_key, item, processing, tx)
            result["outbox"] << item
          end

          # Step 6: advance the partition watermark (monotonic; a regression
          # raises WatermarkRegressionError).
          watermark = advance_watermark_in_tx(partition_key, processing, clock, tx)
          result["watermark"] = watermark

          result["admitted"] = admitted_events
        end
        result
      end

      # Idle-watermark advancement (design §7/P4): when a partition receives no
      # events for `idle_after` virtual-time units, advance its watermark so
      # global progress never silently freezes. Runs in its own transaction;
      # idempotent (a repeated call is a no-op when not yet idle).
      def advance_idle_watermark(partition_key, idle_after:, clock:)
        processing = clock.now_processing
        @adapter.__send__(:transaction, operation: "stream.partition.idle") do |tx|
          row = tx.first(
            "stream.partition.idle.state",
            <<~SQL,
              SELECT watermark, last_processing_time, idleness_at
              FROM tamoz_stream_partitions WHERE partition_key = ?
            SQL
            [partition_key]
          )
          next unless row

          last = row.fetch(1)
          next if processing - last < idle_after

          # Advance to the current processing time (a new watermark must never
          # regress; it equals `now`, which is >= the previous watermark).
          advance_watermark_in_tx(partition_key, processing, clock, tx)
        end
        watermark(partition_key)
      end

      # C3/P5 — the outbox drain. Runs AFTER the processing transaction, with
      # its own lease, and is idempotent by construction: it calls the
      # checkpointer's `enqueue_request` with the stable derived request id, so
      # a drained-twice row is a no-op (same request id + input digest -> no-op;
      # a different payload -> CheckpointConflictError, surfaced typed). A crash
      # between outbox append and drain retries the same row -> one logical
      # episode (invariant 23).
      #
      # The enqueue happens OUTSIDE the drain's read/update transactions (the
      # adapter's transaction is non-reentrant, plan §C3): read the pending
      # rows, enqueue each (own transaction), then mark drained.
      #
      # @param checkpoints [Object] the graph checkpointer exposing
      #   enqueue_request (duck-typed; nil = drain disabled).
      # @return [Array<Hash>] the drained outbox rows.
      def drain_outbox(checkpoints:, clock:)
        return [] unless checkpoints

        pending = @adapter.__send__(:read, operation: "stream.outbox.pending") do |tx|
          tx.rows(
            "stream.outbox.pending",
            "SELECT outbox_id, kind, payload FROM tamoz_stream_outbox " \
            "WHERE drained = 0 ORDER BY created_at_ms LIMIT 100"
          )
        end

        drained = []
        pending.each do |row|
          outbox_id = row.fetch(0)
          payload = JSON.parse(row.fetch(2), create_additions: false)
          # C7: the bridge maps each Situation to its OWN thread namespace
          # `["situation", situation_id]` so the graph's single-fenced-writer
          # rule mechanically enforces one active episode per Situation
          # (invariant 20). The situation_id is carried in the outbox payload.
          situation_id = payload.is_a?(Hash) ? payload["situation_id"] : nil
          thread_id = situation_id ? "situation.#{situation_id}" : "situation"
          # Own transaction (idempotent on the stable request id).
          checkpoints.enqueue_request(
            thread_id:,
            request_id: outbox_id,
            operation: :turn,
            payload: payload
          )
          @adapter.__send__(:transaction, operation: "stream.outbox.mark") do |tx|
            tx.execute(
              "stream.outbox.mark_drained",
              "UPDATE tamoz_stream_outbox SET drained = 1, updated_at_ms = ? WHERE outbox_id = ?",
              [clock.now_processing, outbox_id]
            )
          end
          drained << {"outbox_id" => outbox_id, "kind" => row.fetch(1), "payload" => payload}
        end
        drained
      end

      private

      def admit_in_tx(envelope, clock:, tx:)
        processing = clock.now_processing
        identity = envelope.identity
        existing = tx.first(
          "stream.event.existing",
          "SELECT payload_hash FROM tamoz_stream_events WHERE identity = ?",
          [identity]
        )
        return DUPLICATE if existing && existing.fetch(0) == envelope.payload_hash
        if existing
          tx.execute(
            "stream.event.quarantine",
            <<~SQL,
              UPDATE tamoz_stream_events
              SET outcome = ?, reason = ?, updated_at_ms = ?
              WHERE identity = ? AND payload_hash = ?
            SQL
            [QUARANTINED, "payload hash changed for a reused identity", processing, identity, existing.fetch(0)]
          )
          return QUARANTINED
        end

        tx.execute(
          "stream.event.insert",
          <<~SQL,
            INSERT INTO tamoz_stream_events(
              identity, event_id, event_type, schema_id, schema_version,
              payload_hash, tenant_id, source_id, channel_id,
              channel_revision, partition_key, entity_id, event_time,
              observed_time, ingestion_time, sequence, outcome, reason,
              payload, processing_time, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
          SQL
          [
            identity, envelope.event_id, envelope.event_type,
            envelope.schema_id, envelope.schema_version,
            envelope.payload_hash, envelope.tenant_id, envelope.source_id,
            envelope.channel_id, envelope.channel_revision,
            envelope.partition_key, envelope.entity_id, envelope.event_time,
            envelope.observed_time, envelope.ingestion_time, envelope.sequence,
            ADMITTED, JSON.generate(envelope.payload), processing,
            processing, processing
          ]
        )
        ADMITTED
      end

      def load_operator_state(partition_key, tx)
        row = tx.first(
          "stream.operator.load",
          "SELECT state FROM tamoz_stream_operator_state WHERE partition_key = ?",
          [partition_key]
        )
        row ? JSON.parse(row.fetch(0), create_additions: false) : {}
      end

      def save_operator_state(partition_key, spec_digest, state, processing, tx)
        tx.execute(
          "stream.operator.upsert",
          <<~SQL,
            INSERT INTO tamoz_stream_operator_state(
              partition_key, spec_digest, state, updated_at_ms
            )
            VALUES (?, ?, ?, ?)
            ON CONFLICT(partition_key) DO UPDATE SET
              spec_digest = excluded.spec_digest,
              state = excluded.state,
              updated_at_ms = excluded.updated_at_ms
          SQL
          [partition_key, spec_digest, JSON.generate(Tamoz::Core.canonical(state)), processing]
        )
      end

      def append_situation(partition_key, spec_digest, situation, processing, tx)
        situation_id = situation.fetch("situation_id")
        row = tx.first(
          "stream.situation.current",
          "SELECT current_version FROM tamoz_stream_situation_current WHERE situation_id = ?",
          [situation_id]
        )
        version = (row&.fetch(0) || 0) + 1
        tx.execute(
          "stream.situation.insert",
          <<~SQL,
            INSERT INTO tamoz_stream_situations(
              situation_id, version, spec_digest, phase, facts, hypotheses,
              confidence, evidence, completeness, source_versions,
              payload_digest, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            situation_id, version, spec_digest,
            situation.fetch("phase"),
            JSON.generate(Tamoz::Core.canonical(situation.fetch("facts"))),
            JSON.generate(Tamoz::Core.canonical(situation.fetch("hypotheses"))),
            situation.fetch("confidence"),
            JSON.generate(Tamoz::Core.canonical(situation.fetch("evidence", []))),
            situation.fetch("completeness"),
            JSON.generate(Tamoz::Core.canonical(situation.fetch("source_versions", []))),
            situation.fetch("payload_digest"), processing, processing
          ]
        )
        tx.execute(
          "stream.situation.upsert_current",
          <<~SQL,
            INSERT INTO tamoz_stream_situation_current(
              situation_id, current_version, updated_at_ms
            )
            VALUES (?, ?, ?)
            ON CONFLICT(situation_id) DO UPDATE SET
              current_version = excluded.current_version,
              updated_at_ms = excluded.updated_at_ms
          SQL
          [situation_id, version, processing]
        )
        version
      end

      def append_trigger(partition_key, situation, trigger, situation_version, processing, tx)
        trigger_id = trigger.fetch("trigger_id")
        tx.execute(
          "stream.trigger.insert",
          <<~SQL,
            INSERT INTO tamoz_stream_triggers(
              trigger_id, partition_key, situation_id, scores, evidence,
              reasons, completeness, cost_estimate, freshness, deadline,
              outcome, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            trigger_id, partition_key, situation.fetch("situation_id"),
            JSON.generate(Tamoz::Core.canonical(trigger.fetch("scores"))),
            JSON.generate(Tamoz::Core.canonical(trigger.fetch("evidence", []))),
            JSON.generate(Tamoz::Core.canonical(trigger.fetch("reasons", []))),
            trigger.fetch("completeness"),
            trigger.fetch("cost_estimate"),
            trigger.fetch("freshness"),
            trigger["deadline"],
            trigger.fetch("outcome"),
            processing, processing
          ]
        )
      end

      def append_outbox(partition_key, item, processing, tx)
        outbox_id = item.fetch("outbox_id")
        # Plan C9: an oversized derived request id must fail at BUILD time,
        # never at enqueue. The outbox id becomes the bridge request id, so
        # the Wire request-id bound is enforced before the row exists.
        unless outbox_id.is_a?(String) && outbox_id.bytesize <= 256
          raise Tamoz::Stream::RequestIdTooLongError,
                "outbox_id must fit the request-id bound (256 bytes)"
        end
        payload = Tamoz::Core.canonical(item.fetch("payload"))
        digest = "sha256:#{Digest::SHA256.hexdigest(
          "tamoz.stream.outbox.v1\n" + JSON.generate(payload)
        )}"
        tx.execute(
          "stream.outbox.insert",
          <<~SQL,
            INSERT INTO tamoz_stream_outbox(
              outbox_id, partition_key, kind, payload, payload_digest,
              drained, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
          SQL
          [outbox_id, partition_key, item.fetch("kind"),
           JSON.generate(payload), digest, processing, processing]
        )
      end

      def advance_watermark_in_tx(partition_key, watermark, clock, tx)
        current = tx.scalar(
          "stream.partition.watermark",
          "SELECT watermark FROM tamoz_stream_partitions WHERE partition_key = ?",
          [partition_key]
        )
        if current && watermark < current
          raise Tamoz::Stream::WatermarkRegressionError,
                "partition #{partition_key} watermark regressed from #{current} to #{watermark}"
        end

        if current.nil?
          tx.execute(
            "stream.partition.insert",
            <<~SQL,
              INSERT INTO tamoz_stream_partitions(
                partition_key, watermark, last_processing_time,
                idleness_at, created_at_ms, updated_at_ms
              )
              VALUES (?, ?, ?, NULL, ?, ?)
            SQL
            [partition_key, watermark, watermark, watermark, watermark]
          )
        else
          tx.execute(
            "stream.partition.update",
            <<~SQL,
              UPDATE tamoz_stream_partitions
              SET watermark = ?, last_processing_time = ?, updated_at_ms = ?
              WHERE partition_key = ?
            SQL
            [watermark, watermark, watermark, partition_key]
          )
        end
        watermark
      end
    end
  end
end

