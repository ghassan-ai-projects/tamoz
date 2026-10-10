# frozen_string_literal: true

require 'tamoz/core'

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Inbound admission (design §6, §13): one durable anchor row per update identity, and the
    # turn it admits enqueued in the same transaction as the anchor.
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:TooManyStatements
    class CommsInbound
      include CommsStoreRows

      REQUEST_OPERATION = 'turn'
      REQUEST_DELIVERY = 'queue'
      CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]+/u

      def initialize(adapter:, checkpoints:)
        @adapter = adapter
        @checkpoints = checkpoints
      end

      # The first durable observation of (surface, stream, update_id) anchors dedup: the same
      # payload digest is :duplicate; a DIFFERENT digest is an integrity conflict that moves the
      # one anchor row and enqueues nothing (invariant 1). Intake limits are read from the
      # DEPLOYED surface row inside this transaction, before any insert.
      def admit_and_enqueue(envelope_wire, stream_id:, turn:, now:)
        transaction('comms.admit.enqueue') do |txn|
          anchor = inbound_anchor(txn, envelope_wire, stream_id)
          next replay_outcome(txn, envelope_wire, stream_id, anchor) if anchor

          refusal = intake_refusal(txn, envelope_wire, turn.reservation)
          next refusal if refusal

          request_id = request_id_for(envelope_wire, stream_id)
          insert_inbound!(txn, envelope_wire.merge('disposition' => 'request', 'reason' => 'accepted'), stream_id, now)
          insert_admitted_request!(txn, request_id, envelope_wire, turn, now)
          enqueue!(txn, turn.thread, request_id, REQUEST_OPERATION, turn_payload(envelope_wire, turn, request_id))
          :enqueued
        end
      end

      # Admit one clarification answer and enqueue its resume without a crash
      # window between the inbound anchor and the request inbox row.
      def admit_and_enqueue_answer(envelope_wire, stream_id:, resume:, now:)
        transaction('comms.admit.answer') do |txn|
          anchor = inbound_anchor(txn, envelope_wire, stream_id)
          next replay_outcome(txn, envelope_wire, stream_id, anchor) if anchor

          enqueue!(txn, resume.thread, resume.request_id, 'resume', resume.payload)
          row = envelope_wire.merge('disposition' => 'ignored', 'reason' => 'clarification_answer',
                                    'request_id' => resume.request_id)
          insert_inbound!(txn, row, stream_id, now)
          :enqueued
        end
      end

      def inbound_observed?(envelope_wire, stream_id:)
        read('comms.admit.inbound.observed') { |txn| !inbound_anchor(txn, envelope_wire, stream_id).nil? }
      end

      # Record a non-request disposition durably: the first observation inserts its anchor row; a
      # conflicting digest for a known identity updates that anchor and returns :conflict_recorded.
      def disposition_only(envelope_wire, stream_id:, disposition:, reason:, now:)
        transaction('comms.admit.disposition') do |txn|
          next :duplicate if identical_inbound_row?(txn, envelope_wire, stream_id)

          anchor = inbound_anchor(txn, envelope_wire, stream_id)
          next :duplicate if anchor && anchor[1] == envelope_wire.fetch('raw_payload_hash') &&
                             anchor[2] == disposition && anchor[3] == reason

          if anchor
            record_inbound_conflict!(txn, envelope_wire, stream_id, disposition:, reason:)
            next :conflict_recorded
          end

          insert_inbound!(txn, envelope_wire.merge('disposition' => disposition, 'reason' => reason), stream_id, now)
          :recorded
        end
      end

      private

      def replay_outcome(txn, envelope_wire, stream_id, anchor)
        return :duplicate if anchor[0] == envelope_wire.fetch('raw_payload_hash')

        record_inbound_conflict!(txn, envelope_wire, stream_id)
        :integrity_conflict
      end

      # Pending+claimed deliveries plus open reservations must stay under outbox_capacity, so the
      # reserved terminal answer can always append (design §12, invariant 57).
      def intake_refusal(txn, envelope_wire, reservation)
        surface_id = envelope_wire.fetch('surface_id')
        limits = deployed_surface_limits(txn, surface_id)
        return :open_request_limit if open_request_count(txn, surface_id) >= limits.fetch('max_open_requests')

        text = envelope_wire['text']
        return :inbound_too_large if text && text.bytesize > limits.fetch('max_inbound_bytes')

        used = pending_claimed_count(txn, surface_id) + open_reservations(txn, surface_id)
        :capacity_refused if used + reservation > limits.fetch('outbox_capacity')
      end

      def enqueue!(txn, thread, request_id, operation, payload)
        payload_bytes, payload_digest, input_digest = encode_request(operation, REQUEST_DELIVERY, payload)
        @checkpoints.enqueue_request_in_transaction!(
          txn, thread:, encoded_namespace: DEFAULT_NAMESPACE, id: request_id, operation_text: operation,
               delivery_text: REQUEST_DELIVERY, payload_bytes:, payload_digest:, input_digest:
        )
      end

      # The transcript nests with the text under the task Hash, the shape the graph's
      # payload-to-channel mapping tolerates; research and attachment ride beside it.
      def turn_payload(envelope_wire, turn, request_id)
        fragments = turn.history.filter_map do |fragment|
          flattened = flatten_context_text(fragment.fetch('text'))
          { 'role' => fragment.fetch('role'), 'text' => flattened } unless flattened.empty?
        end
        Tamoz::Core::TurnContext.task(thread_id: turn.thread, request_id:,
                                      text: flatten_context_text(envelope_wire.fetch('text')), fragments:)
                                .merge({ 'research' => turn.research, 'attachment' => turn.attachment }.compact)
      end

      # TurnContext forbids control characters; a multi-line message or transcript fragment is
      # flattened to one space so admission and every later turn stay durable.
      def flatten_context_text(text) = String(text).gsub(CONTROL_CHARACTERS, ' ').strip

      # The caller's descriptor copy can drift from the durable deployment; the row is the truth.
      def deployed_surface_limits(txn, surface_id)
        row = txn.first('comms.admit.limits', <<~SQL, [surface_id])
          SELECT descriptor_json FROM tamoz_comms_surfaces WHERE surface_id = ?
        SQL
        raise KeyError, "surface #{surface_id} is not deployed" unless row

        JSON.parse(row.fetch(0)).fetch('limits')
      end

      def open_request_count(txn, surface_id)
        txn.scalar('comms.admit.limit.open_requests', <<~SQL, [surface_id]).to_i
          SELECT COUNT(*) FROM tamoz_comms_requests
          WHERE surface_id = ? AND projection_state = 'admitted'
        SQL
      end

      def insert_admitted_request!(txn, request_id, envelope_wire, turn, now)
        binds = [request_id, envelope_wire.fetch('surface_id'), envelope_wire.fetch('surface_revision'),
                 envelope_wire.fetch('conversation_id'), turn.thread, turn.profile_id,
                 turn.reservation, now_ms(now), now_ms(now)]
        txn.execute('comms.admit.request.upsert', <<~SQL, binds)
          INSERT OR IGNORE INTO tamoz_comms_requests (
            request_id, surface_id, surface_revision, conversation_id,
            thread_id, profile_id, reservation, projection_state,
            created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'admitted', ?, ?)
        SQL
      end

      def request_id_for(envelope_wire, stream_id)
        Tamoz::Core::RequestIdentity.request_id(
          stream_id:, **envelope_wire.slice('surface_id', 'surface_revision', 'update_id', 'raw_payload_hash')
                                     .transform_keys(&:to_sym)
        )
      end

      # The ONE durable anchor row for an update identity (invariant 1): its original payload digest
      # plus the last conflicting digest seen and the disposition those bytes currently carry.
      def inbound_anchor(txn, envelope_wire, stream_id)
        txn.first('comms.admit.inbound.anchor', <<~SQL, identity_binds(envelope_wire, stream_id))
          SELECT raw_payload_hash, last_conflict_digest, disposition, reason
          FROM tamoz_comms_inbound
          WHERE surface_id = ? AND stream_id = ? AND update_id = ?
          LIMIT 1
        SQL
      end

      # A disposition re-record dedups only on the FULL identity (digest included), so a
      # conflicting digest can still be recorded quarantined.
      def identical_inbound_row?(txn, envelope_wire, stream_id)
        binds = identity_binds(envelope_wire, stream_id) + [envelope_wire.fetch('raw_payload_hash')]
        txn.first('comms.admit.inbound.identical', <<~SQL, binds)
          SELECT 1 FROM tamoz_comms_inbound
          WHERE surface_id = ? AND stream_id = ? AND update_id = ? AND raw_payload_hash = ?
        SQL
      end

      def identity_binds(envelope_wire, stream_id)
        [envelope_wire.fetch('surface_id'), stream_id, envelope_wire.fetch('update_id')]
      end

      # `row` is the envelope wire plus its disposition, reason and (when admitted) request id.
      def insert_inbound!(txn, row, stream_id, now)
        binds = [row.fetch('surface_id'), row.fetch('surface_revision'), stream_id, row.fetch('update_id'),
                 row.fetch('raw_payload_hash'), row.fetch('parser_version'), row.fetch('kind'),
                 row.fetch('correspondent_id'), row.fetch('conversation_id'), row.fetch('disposition'),
                 row.fetch('reason'), row['request_id'], row['decision_id'],
                 wire_time_ms(row['observed_time']), now_ms(now)]
        txn.execute('comms.admit.inbound.insert', <<~SQL, binds)
          INSERT INTO tamoz_comms_inbound (
            surface_id, surface_revision, stream_id, update_id, raw_payload_hash,
            parser_version, kind, correspondent_id, conversation_id,
            disposition, reason, request_id, decision_id,
            observed_at_ms, ingested_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      # A conflicting observation never becomes a row of its own: it moves the anchor's
      # last_conflict_digest and counts once per DISTINCT conflicting digest.
      def record_inbound_conflict!(txn, envelope_wire, stream_id, disposition: nil, reason: nil)
        hash = envelope_wire.fetch('raw_payload_hash')
        txn.execute('comms.admit.inbound.conflict',
                    <<~SQL, [hash, hash, disposition, reason] + identity_binds(envelope_wire, stream_id))
                      UPDATE tamoz_comms_inbound
                      SET conflict_count = conflict_count + CASE WHEN last_conflict_digest = ?
                            THEN 0 ELSE 1 END,
                          last_conflict_digest = ?,
                          disposition = COALESCE(?, disposition),
                          reason = COALESCE(?, reason)
                      WHERE surface_id = ? AND stream_id = ? AND update_id = ?
                    SQL
      end
    end
  end
end
