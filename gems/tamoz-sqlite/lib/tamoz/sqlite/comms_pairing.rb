# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Pairing challenges (design §7): stored as digests, never the plaintext code, and consumed
    # together with the binding they grant.
    class CommsPairing
      include CommsStoreRows

      PAIRING_COLUMNS = %w[
        challenge_digest surface_id correspondent_id conversation_id status
        attempts expires_at_ms created_at_ms
      ].freeze
      def initialize(adapter:, routes:)
        @adapter = adapter
        @routes = routes
      end

      # Pending scans exclude expired challenges so they stop accumulating under the read path; the
      # surface/correspondent filters run in SQL so per-sender scans stay bounded.
      def pairing_challenges(status: nil, surface_id: nil, correspondent_id: nil, now: nil)
        read('comms.pairing.list') do |txn|
          filters = { 'status = ?' => status, 'surface_id = ?' => surface_id,
                      'correspondent_id = ?' => correspondent_id }
          filters['expires_at_ms > ?'] = backend_now_ms(txn, now) if status == 'pending'
          filters.compact!
          sql = "SELECT #{PAIRING_COLUMNS.join(', ')} FROM tamoz_comms_pairing_challenges"
          sql += " WHERE #{filters.keys.join(' AND ')}" unless filters.empty?
          txn.rows('comms.pairing.list', "#{sql} ORDER BY created_at_ms DESC", filters.values)
             .map { |row| PAIRING_COLUMNS.zip(row).to_h }
        end
      end

      # Idempotent on the digest. Older LIVE pending challenges for the same (surface, correspondent,
      # conversation) are superseded in the same transaction — one live code per triple — while
      # consumed and expired rows stay for the audit trail.
      def insert_pairing_challenge(challenge_wire, now:)
        digest = challenge_wire.fetch('challenge_digest')
        triple = challenge_wire.values_at('surface_id', 'correspondent_id', 'conversation_id')
        transaction('comms.pairing.insert') do |txn|
          txn.execute('comms.pairing.insert.supersede', <<~SQL, triple + [backend_now_ms(txn, now), digest])
            DELETE FROM tamoz_comms_pairing_challenges
            WHERE surface_id = ? AND correspondent_id = ? AND conversation_id = ?
              AND status = 'pending' AND expires_at_ms > ? AND challenge_digest != ?
          SQL
          binds = [digest, *triple, wire_time_ms(challenge_wire.fetch('expires_at')), now_ms(now)]
          txn.execute('comms.pairing.insert', <<~SQL, binds)
            INSERT OR IGNORE INTO tamoz_comms_pairing_challenges (
              challenge_digest, surface_id, correspondent_id, conversation_id,
              status, attempts, expires_at_ms, created_at_ms
            ) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
          SQL
          txn.changes == 1 ? :inserted : :duplicate
        end
      end

      # Consume ONE pending challenge and write its binding in one transaction: a crash between the two
      # would leave a consumed challenge that grants nothing. Expiry is re-checked HERE, where
      # authority is granted, so an expired-but-still-pending row can never be approved.
      def approve_pairing(challenge_digest:, binding_wire:, now:)
        transaction('comms.pairing.approve') do |txn|
          txn.execute('comms.pairing.approve.consume', <<~SQL, [challenge_digest, backend_now_ms(txn, now)])
            UPDATE tamoz_comms_pairing_challenges SET status = 'consumed'
            WHERE challenge_digest = ? AND status = 'pending' AND expires_at_ms > ?
          SQL
          next :missing unless txn.changes == 1
          next :already_bound unless @routes.bind_correspondent_in_transaction!(txn, binding_wire, now:) == :bound

          :approved
        end
      end
    end
  end
end
