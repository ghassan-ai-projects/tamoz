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
    end
  end
end
