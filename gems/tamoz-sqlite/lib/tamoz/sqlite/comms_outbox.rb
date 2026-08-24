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

      # Per-request ceiling on milestone rows (plan 03, work item 2): past it,
      # further milestones replace the newest live row instead of growing.
      MILESTONE_BOUND = 32

      def initialize(adapter:)
        @adapter = adapter
      end

      # Append one desired delivery. Bounded (invariant 57, design §12):
      # pending+claimed rows at capacity are :capacity_refused; the derived id
      # dedups re-appends. A terminal/prompt row passes its request's
      # reservation, so only the OTHER admitted requests' reservations count —
      # the reserved terminal answer can always append. A control row has no
      # reservation and refuses when total slots are at capacity.
      # A journaled=0 progress milestone (markup naming a request_ref) is
      # COALESCED instead: while the request's live pending milestone row
      # exists it is updated in place; past MILESTONE_BOUND milestone rows for
      # the reference with no pending row left, further milestones are DROPPED
      # rather than rewritten onto delivered history.
      def append_delivery(delivery_wire, surface_id:, capacity:, now:, reserved_request_id: nil)
        transaction('comms.outbox.append') do |txn|
          if (request_ref = milestone_request_ref(delivery_wire))
            next :coalesced if coalesce_milestone!(txn, delivery_wire, surface_id, request_ref, now)
            next :coalesced if milestone_bound_reached?(txn, surface_id,
                                                        delivery_wire.fetch('conversation_id'), request_ref)
          end

          existing = txn.first('comms.outbox.append.existing', <<~SQL, [delivery_wire.fetch('delivery_id')])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :duplicate if existing

          pending = pending_claimed_count(txn, surface_id)
          reserved = if reserved_request_id
                       [open_reservations(txn, surface_id) - reservation_of(txn, reserved_request_id), 0].max
                     else
                       open_reservations(txn, surface_id)
                     end
          next :capacity_refused if pending + reserved + 1 > capacity

          txn.execute('comms.outbox.append', <<~SQL, outbox_binds(delivery_wire, surface_id, now))
            INSERT INTO tamoz_comms_outbox (
              delivery_id, surface_id, conversation_id, kind, operation, text,
              part_index, part_count, markup, reply_to, journaled,
              content_digest, render_version, expires_at_ms, status,
              created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
          SQL
          :appended
        end
      end

      # Claim one row under a fenced lease for a transport attempt. A crashed
      # claim is retryable only when the transport boundary was never crossed;
      # marked sends become unknown during reconciliation.
      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        transaction('comms.outbox.claim') do |txn|
          missing = txn.first('comms.outbox.claim.exists', <<~SQL, [delivery_id])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :missing unless missing

          txn.execute('comms.outbox.claim', <<~SQL, [owner, fence, now_ms(claim_expires_at), delivery_id, now_ms(now)])
            UPDATE tamoz_comms_outbox
            SET status = 'claimed', claim_owner = ?, claim_fence = ?, claim_expires_at_ms = ?
            WHERE delivery_id = ? AND (
              status = 'pending' OR
              (status = 'claimed' AND claim_expires_at_ms <= ? AND send_started_at_ms IS NULL)
            )
          SQL
          txn.changes == 1 ? :claimed : :not_claimable
        end
      end

      def reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:, global_messages_per_s:, now:)
        validate_rate!(per_chat_messages_per_s, 'per_chat_messages_per_s')
        validate_rate!(global_messages_per_s, 'global_messages_per_s')
        current_ms = now_ms(now)
        global_interval = interval_ms(global_messages_per_s)
        chat_interval = interval_ms(per_chat_messages_per_s)
        transaction('comms.outbox.pacing.reserve') do |txn|
          global_ready = [current_ms, pacing_time(txn, surface_id, PACING_GLOBAL_SCOPE)].max
          chat_ready = if conversation_id
                         [current_ms, pacing_time(txn, surface_id, conversation_id)].max
                       else
                         current_ms
                       end
          scheduled = [global_ready, chat_ready].max
          upsert_pacing!(txn, surface_id, PACING_GLOBAL_SCOPE, scheduled + global_interval)
          upsert_pacing!(txn, surface_id, conversation_id, scheduled + chat_interval) if conversation_id
          (scheduled - current_ms) / 1000.0
        end
      end

      def release_delivery_claim(delivery_id:, owner:, fence:, now:)
        transaction('comms.outbox.release_claim') do |txn|
          txn.execute('comms.outbox.release_claim', <<~SQL, [now_ms(now), delivery_id, owner, fence])
            UPDATE tamoz_comms_outbox
            SET status = 'pending', claim_owner = NULL, claim_fence = NULL,
                claim_expires_at_ms = NULL, send_started_at_ms = NULL, updated_at_ms = ?
            WHERE delivery_id = ? AND status = 'claimed'
              AND claim_owner = ? AND claim_fence = ?
          SQL
          txn.changes == 1 ? :released : :not_claimable
        end
      end

      def mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
        transaction('comms.outbox.send_started') do |txn|
          txn.execute('comms.outbox.send_started', <<~SQL, [now_ms(now), now_ms(now), delivery_id, owner, fence])
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

      def defer_delivery(surface_id:, conversation_id:, not_before:, now:)
        deadline = [now_ms(now), now_ms(not_before)].max
        transaction('comms.outbox.pacing.defer') do |txn|
          scopes = [PACING_GLOBAL_SCOPE, conversation_id].compact.uniq
          scopes.each do |scope|
            current = pacing_time(txn, surface_id, scope)
            upsert_pacing!(txn, surface_id, scope, [current, deadline].max)
          end
          :deferred
        end
      end

      # Bind one row to its effect journal entry (design §10): the journal
      # holds attempts and receipts, never the outbox. Write-once.
      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        transaction('comms.outbox.bind_effect') do |txn|
          missing = txn.first('comms.outbox.bind_effect.exists', <<~SQL, [delivery_id])
            SELECT effect_key FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :missing unless missing

          return :conflict if missing[0] && missing[0] != effect_key

          txn.execute('comms.outbox.bind_effect', <<~SQL, [effect_key, execution_id, now_ms(now), delivery_id])
            UPDATE tamoz_comms_outbox
            SET effect_key = ?, effect_execution_id = ?, updated_at_ms = ?
            WHERE delivery_id = ? AND effect_key IS NULL
          SQL
          :bound
        end
      end

      def outbox_rows(surface_id:, statuses:, limit: 500)
        read('comms.outbox.rows') do |txn|
          placeholders = statuses.map { '?' }.join(', ')
          rows = txn.rows('comms.outbox.rows', <<~SQL, [surface_id, *statuses, limit])
            SELECT #{OUTBOX_COLUMNS.join(', ')} FROM tamoz_comms_outbox
            WHERE surface_id = ? AND status IN (#{placeholders})
            ORDER BY created_at_ms LIMIT ?
          SQL
          rows.map { |row| OUTBOX_COLUMNS.zip(row).to_h }
        end
      end

      # Record a transport outcome for a CLAIMED row — fenced (invariant 4):
      # the UPDATE must match the claim's owner AND fence, so a stale drainer
      # records nothing. `succeeded` carries the receipt, `unknown` is the
      # honest ambiguity state (design §10 — never a guess, never an
      # automatic retry).
      def mark_delivery(delivery_id:, owner:, fence:, status:, now:, receipt: nil)
        transaction('comms.outbox.mark') do |txn|
          txn.execute('comms.outbox.mark',
                      <<~SQL, [status, receipt && JSON.generate(receipt), now_ms(now), delivery_id, owner, fence])
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

      # The request reference a progress milestone row projects, or nil for
      # every other delivery shape. Milestones are exactly the journaled=0
      # control rows whose markup names a milestone and a request_ref.
      def milestone_request_ref(delivery_wire)
        markup = delivery_wire['markup']
        return nil unless delivery_wire.fetch('kind') == 'control' &&
                          delivery_wire.fetch('journaled') == false && markup.is_a?(String)

        facts = JSON.parse(markup)
        facts['request_ref'] if facts.is_a?(Hash) && facts['request_ref'].is_a?(String) &&
                                facts['milestone'].is_a?(String)
      rescue JSON::ParserError
        nil
      end

      def coalesce_milestone!(txn, delivery_wire, surface_id, request_ref, now)
        live = milestone_rows(txn, surface_id, delivery_wire.fetch('conversation_id'), request_ref,
                              "AND status = 'pending'").first
        return false unless live

        rewrite_milestone!(txn, delivery_wire, live.fetch(:delivery_id), now)
        true
      end

      # Past the bound with no pending row to coalesce into, the new milestone
      # is dropped: a rewrite would land on a claimed or delivered row and
      # resend old bytes under new content.
      def milestone_bound_reached?(txn, surface_id, conversation_id, request_ref)
        milestone_rows(txn, surface_id, conversation_id, request_ref).length >= MILESTONE_BOUND
      end

      # Newest first, so `first` is always the live row a coalesce update
      # replaces. The markup facts are filtered in SQL so LIMIT is a true
      # ceiling over the matching rows.
      def milestone_rows(txn, surface_id, conversation_id, request_ref, status_clause = '')
        rows = txn.rows('comms.outbox.milestones', <<~SQL, [surface_id, conversation_id, request_ref])
          SELECT delivery_id FROM tamoz_comms_outbox
          WHERE surface_id = ? AND conversation_id = ? AND kind = 'control'
            AND journaled = 0 AND markup IS NOT NULL #{status_clause}
            AND json_extract(markup, '$.request_ref') = ?
            AND json_extract(markup, '$.milestone') IS NOT NULL
          ORDER BY created_at_ms DESC, updated_at_ms DESC, delivery_id DESC LIMIT 500
        SQL
        rows.map { |(delivery_id)| { delivery_id:, request_ref: } }
      end

      # The milestone text/markup move to the new fact in place; journaled
      # stays 0 and the row keeps its status, id, and effect binding.
      def rewrite_milestone!(txn, delivery_wire, delivery_id, now)
        txn.execute('comms.outbox.milestone.rewrite', <<~SQL, [delivery_wire.fetch('text'), delivery_wire['markup'], delivery_wire.fetch('content_digest'), now_ms(now), delivery_id])
          UPDATE tamoz_comms_outbox
          SET text = ?, markup = ?, content_digest = ?, updated_at_ms = ?
          WHERE delivery_id = ?
        SQL
      end

      def validate_rate!(value, name)
        return if value.is_a?(Numeric) && value.positive?

        raise ArgumentError, "#{name} must be a positive number"
      end

      def interval_ms(rate)
        (1000.0 / rate).ceil
      end

      def pacing_time(txn, surface_id, scope)
        return 0 unless scope

        txn.scalar('comms.outbox.pacing.read', <<~SQL, [surface_id, scope]).to_i
          SELECT next_allowed_at_ms FROM tamoz_comms_delivery_pacing
          WHERE surface_id = ? AND scope = ?
        SQL
      end

      def upsert_pacing!(txn, surface_id, scope, next_allowed_at_ms)
        txn.execute('comms.outbox.pacing.upsert', <<~SQL, [surface_id, scope, next_allowed_at_ms])
          INSERT INTO tamoz_comms_delivery_pacing (surface_id, scope, next_allowed_at_ms)
          VALUES (?, ?, ?)
          ON CONFLICT(surface_id, scope) DO UPDATE SET
            next_allowed_at_ms = excluded.next_allowed_at_ms
        SQL
      end

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end
    end
  end
end
