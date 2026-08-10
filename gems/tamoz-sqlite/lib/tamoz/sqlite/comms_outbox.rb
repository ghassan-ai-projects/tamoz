# frozen_string_literal: true

require 'time'

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # The bounded delivery outbox (design §13). Rows journal through
    # tamoz_effects and never duplicate attempts or receipts; a claim is a
    # compare-and-set and the row's effect binding is write-once. Bounded by
    # the surface's outbox_capacity (invariant 57).
    #
    # :reek:LongParameterList -- the primitives mirror the §13 contract
    #   signatures.
    class CommsOutbox
      include CommsStoreRows

      def initialize(adapter:)
        @adapter = adapter
      end

      # Append one desired delivery. Bounded: pending+claimed rows at capacity
      # are :capacity_refused; the derived id dedups re-appends.
      def append_delivery(delivery_wire, surface_id:, capacity:, now:)
        transaction('comms.outbox.append') do |txn|
          existing = txn.first('comms.outbox.append.existing', <<~SQL, [delivery_wire.fetch('delivery_id')])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :duplicate if existing

          pending = txn.scalar('comms.outbox.append.count', <<~SQL, [surface_id])
            SELECT COUNT(*) FROM tamoz_comms_outbox
            WHERE surface_id = ? AND status IN ('pending', 'claimed')
          SQL
          next :capacity_refused if pending >= capacity

          txn.execute('comms.outbox.append', <<~SQL, outbox_binds(delivery_wire, surface_id, now))
            INSERT INTO tamoz_comms_outbox (
              delivery_id, surface_id, conversation_id, kind, operation, text,
              part_index, part_count, markup, journaled, content_digest,
              render_version, expires_at_ms, status, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
          SQL
          :appended
        end
      end

      # Claim one row under a fenced lease for a transport attempt. An expired
      # lease is not automatically re-claimable in v1 — the gateway resolves
      # the effect first (design §10 ambiguity handling).
      # rubocop:disable Lint/UnusedMethodArgument -- `now` keeps the §13
      # contract clock signature; the lease deadline is claim_expires_at.
      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        transaction('comms.outbox.claim') do |txn|
          missing = txn.first('comms.outbox.claim.exists', <<~SQL, [delivery_id])
            SELECT 1 FROM tamoz_comms_outbox WHERE delivery_id = ?
          SQL
          next :missing unless missing

          txn.execute('comms.outbox.claim', <<~SQL, [owner, fence, now_ms(claim_expires_at), delivery_id])
            UPDATE tamoz_comms_outbox
            SET status = 'claimed', claim_owner = ?, claim_fence = ?, claim_expires_at_ms = ?
            WHERE delivery_id = ? AND status = 'pending'
          SQL
          txn.changes == 1 ? :claimed : :not_claimable
        end
      end

      # rubocop:enable Lint/UnusedMethodArgument

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

      private

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end
    end
  end
end
