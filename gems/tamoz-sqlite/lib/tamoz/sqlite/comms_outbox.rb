# frozen_string_literal: true

require 'time'
require 'json'

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # The bounded delivery outbox (design §13). Rows journal through
    # tamoz_effects and never duplicate attempts or receipts; a claim is a
    # compare-and-set and the row's effect binding is write-once. Bounded by
    # the surface's outbox_capacity (invariant 57).
    #
    # :reek:LongParameterList, :reek:DuplicateMethodCall, :reek:NilCheck
    # :reek:TooManyStatements, :reek:FeatureEnvy, :reek:DataClump
    # :reek:NestedIterators, :reek:UnusedParameters -- the primitives mirror
    #   the §13 contract signatures and their one-transaction bodies.
    class CommsOutbox
      include CommsStoreRows

      # Per-request FIFO: a pending part is ineligible while an earlier part of
      # the same request is `unknown` (its send crossed the transport boundary
      # but is not yet resolved), so a later part cannot be delivered before an
      # ambiguous predecessor is decided. Rows of one render share a
      # `created_at_ms` and `delivery_id` is a content digest, so only `rowid`
      # orders them by append. A NULL `request_id` never matches here, which
      # keeps control replies and other requests draining; resolving the
      # predecessor unblocks the row.
      CLAIM_DELIVERY_SQL = <<~SQL
        UPDATE tamoz_comms_outbox
        SET status = 'claimed', claim_owner = ?, claim_fence = ?, claim_expires_at_ms = ?
        WHERE delivery_id = ? AND (
          status = 'pending' OR
          (status = 'claimed' AND claim_expires_at_ms <= ? AND send_started_at_ms IS NULL)
        )
        AND NOT EXISTS (
          SELECT 1 FROM tamoz_comms_outbox AS pred
          WHERE pred.surface_id = tamoz_comms_outbox.surface_id
            AND pred.conversation_id = tamoz_comms_outbox.conversation_id
            AND pred.request_id = tamoz_comms_outbox.request_id
            AND pred.status = 'unknown'
            AND pred.rowid < tamoz_comms_outbox.rowid
        )
      SQL

      def initialize(adapter:)
        @adapter = adapter
      end

      # Append one desired delivery. Bounded (invariant 57, design §12):
      # pending+claimed rows at capacity are :capacity_refused; the derived id
      # dedups re-appends. A terminal/prompt row passes its request's
      # reservation, so only the OTHER admitted requests' reservations count —
      # the reserved terminal answer can always append. A control row has no
      # reservation and refuses when total slots are at capacity.
      def append_delivery(delivery_wire, surface_id:, capacity:, now:, reserved_request_id: nil)
        transaction('comms.outbox.append') do |txn|
          existing = txn.first('comms.outbox.append.existing', <<~SQL, [delivery_wire.fetch('delivery_id')])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :duplicate if existing
          next :capacity_refused if slots_in_use(txn, surface_id, reserved_request_id) + 1 > capacity

          insert_delivery!(txn, outbox_binds(delivery_wire, surface_id, now, request_id: reserved_request_id))
          :appended
        end
      end

      # Claim one row under a fenced lease for a transport attempt. A crashed
      # claim is retryable only when the transport boundary was never crossed;
      # marked sends become unknown during reconciliation.
      def claim_delivery(delivery_id:, lease:, claim_expires_at:, now:)
        transaction('comms.outbox.claim') do |txn|
          existing = txn.first('comms.outbox.claim.exists', <<~SQL, [delivery_id])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :missing unless existing

          txn.execute('comms.outbox.claim', CLAIM_DELIVERY_SQL,
                      [lease.fetch('owner'), lease.fetch('fence'), now_ms(claim_expires_at), delivery_id, now_ms(now)])
          txn.changes == 1 ? :claimed : :not_claimable
        end
      end

      def release_delivery_claim(delivery_id:, lease:, now:)
        transaction('comms.outbox.release_claim') do |txn|
          txn.execute('comms.outbox.release_claim',
                      <<~SQL, [now_ms(now), delivery_id, lease.fetch('owner'), lease.fetch('fence')])
                        UPDATE tamoz_comms_outbox
                        SET status = 'pending', claim_owner = NULL, claim_fence = NULL,
                            claim_expires_at_ms = NULL, send_started_at_ms = NULL, updated_at_ms = ?
                        WHERE delivery_id = ? AND status = 'claimed'
                          AND claim_owner = ? AND claim_fence = ?
                      SQL
          txn.changes == 1 ? :released : :not_claimable
        end
      end

      def mark_delivery_send_started(delivery_id:, lease:, now:)
        transaction('comms.outbox.send_started') do |txn|
          txn.execute('comms.outbox.send_started',
                      <<~SQL, [now_ms(now), now_ms(now), delivery_id, lease.fetch('owner'), lease.fetch('fence')])
                        UPDATE tamoz_comms_outbox
                        SET send_started_at_ms = ?, updated_at_ms = ?
                        WHERE delivery_id = ? AND status = 'claimed'
                          AND claim_owner = ? AND claim_fence = ?
                      SQL
          txn.changes == 1 ? :marked : :not_claimable
        end
      end

      def reconcile_expired_deliveries(now:)
        transaction('comms.outbox.reconcile_expired') do |txn|
          txn.execute('comms.outbox.reconcile_expired', <<~SQL, [now_ms(now), now_ms(now)])
            UPDATE tamoz_comms_outbox
            SET status = 'unknown', updated_at_ms = ?
            WHERE status = 'claimed' AND claim_expires_at_ms <= ?
              AND send_started_at_ms IS NOT NULL
          SQL
          txn.execute('comms.outbox.reconcile_unstarted', <<~SQL, [now_ms(now), now_ms(now)])
            UPDATE tamoz_comms_outbox
            SET status = 'pending', claim_owner = NULL, claim_fence = NULL,
                claim_expires_at_ms = NULL, updated_at_ms = ?
            WHERE status = 'claimed' AND claim_expires_at_ms <= ?
              AND send_started_at_ms IS NULL
          SQL
          txn.changes
        end
      end

      # Bind one row to its effect journal entry (design §10): the journal
      # holds attempts and receipts, never the outbox. Write-once.
      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        transaction('comms.outbox.bind_effect') do |txn|
          existing = txn.first('comms.outbox.bind_effect.exists', <<~SQL, [delivery_id])
            SELECT effect_key FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :missing unless existing

          return :conflict if existing[0] && existing[0] != effect_key

          txn.execute('comms.outbox.bind_effect', <<~SQL, [effect_key, execution_id, now_ms(now), delivery_id])
            UPDATE tamoz_comms_outbox
            SET effect_key = ?, effect_execution_id = ?, updated_at_ms = ?
            WHERE delivery_id = ? AND effect_key IS NULL
          SQL
          :bound
        end
      end

      # Record a transport outcome for a CLAIMED row — fenced (invariant 4):
      # the UPDATE must match the claim's lease, so a stale drainer
      # records nothing. `succeeded` carries the receipt, `unknown` is the
      # honest ambiguity state (design §10 — never a guess, never an
      # automatic retry).
      def mark_delivery(delivery_id:, lease:, status:, now:, receipt: nil)
        transaction('comms.outbox.mark') do |txn|
          binds = [status, receipt && JSON.generate(receipt), now_ms(now), delivery_id, lease.fetch('owner'),
                   lease.fetch('fence')]
          txn.execute('comms.outbox.mark', <<~SQL, binds)
            UPDATE tamoz_comms_outbox
            SET status = ?, receipt = ?, updated_at_ms = ?
            WHERE delivery_id = ? AND status = 'claimed'
              AND claim_owner = ? AND claim_fence = ?
          SQL
          txn.changes == 1 ? :marked : :not_claimable
        end
      end

      # The OPERATOR's explicit resolution of a genuinely ambiguous send
      # (design §14): an `unknown` row is resolved to succeeded or failed,
      # never retried blindly. Only the operator's resolve command calls this.
      def resolve_delivery(delivery_id:, status:, now:)
        transaction('comms.outbox.resolve') do |txn|
          txn.execute('comms.outbox.resolve', <<~SQL, [status, now_ms(now), delivery_id])
            UPDATE tamoz_comms_outbox
            SET status = ?, updated_at_ms = ?
            WHERE delivery_id = ? AND status = 'unknown'
          SQL
          txn.changes == 1 ? :resolved : :not_unknown
        end
      end

      private

      # A terminal or prompt row's own request reservation covers it; only the OTHER admitted requests'
      # reservations count, so the reserved terminal answer can always append.
      def slots_in_use(txn, surface_id, reserved_request_id)
        reserved = open_reservations(txn, surface_id)
        reserved = [reserved - reservation_of(txn, reserved_request_id), 0].max if reserved_request_id
        pending_claimed_count(txn, surface_id) + reserved
      end

      def insert_delivery!(txn, binds)
        txn.execute('comms.outbox.append', <<~SQL, binds)
          INSERT INTO tamoz_comms_outbox (
            delivery_id, surface_id, conversation_id, kind, operation, text,
            part_index, part_count, markup, reply_to, journaled,
            content_digest, render_version, expires_at_ms, status,
            created_at_ms, updated_at_ms, request_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
        SQL
      end

      def reservation_of(txn, request_id)
        txn.scalar('comms.admit.capacity.request', <<~SQL, [request_id]).to_i
          SELECT reservation FROM tamoz_comms_requests
          WHERE request_id = ? AND projection_state = 'admitted'
        SQL
      end

      def outbox_binds(delivery_wire, surface_id, now, request_id:)
        [
          delivery_wire.fetch('delivery_id'), surface_id, delivery_wire.fetch('conversation_id'),
          delivery_wire.fetch('kind'), delivery_wire.fetch('operation'), delivery_wire.fetch('text'),
          delivery_wire.fetch('part_index'), delivery_wire.fetch('part_count'), delivery_wire['markup'],
          delivery_wire['reply_to'],
          delivery_wire.fetch('journaled') ? 1 : 0, delivery_wire.fetch('content_digest'),
          delivery_wire.fetch('render_version'),
          wire_time_ms(delivery_wire['expires_at']),
          now_ms(now), now_ms(now), request_id
        ]
      end
    end
  end
end
