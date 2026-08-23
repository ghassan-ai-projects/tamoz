# frozen_string_literal: true

require 'tamoz/approval'

module Tamoz
  module SQLite
    # SQLite implementation of the Tamoz::Approval::GrantStore port
    # (approval-policy-redesign ADR §2.3). Lookup is an exact tuple match on
    # (key, scope, session_id, policy_rev) — a stale-rev grant after a reload
    # simply never matches, fail closed with no grandfathering. Expiry is the
    # Engine's concern; key text goes through Grant.key_text on BOTH sides so
    # an inserted row and its lookup always serialize identically.
    class ApprovalGrantStore < Approval::GrantStore
      def initialize(adapter:)
        @adapter = adapter
      end

      def lookup(key:, scope:, session_id:, policy_rev:)
        @adapter.__send__(:read, operation: 'approval.grant.lookup') do |txn|
          row = txn.first('approval.grant.lookup', <<~SQL, [Approval::Grant.key_text(key), scope.to_s, session_id, policy_rev])
            SELECT created_at_ms, expires_at_ms FROM tamoz_approval_grants
            WHERE key = ? AND scope = ? AND session_id = ? AND policy_rev = ?
            LIMIT 1
          SQL
          row && Approval::Grant.new(
            key: key,
            scope: scope,
            session_id: session_id,
            policy_rev: policy_rev,
            created_at_ms: row.fetch(0),
            expires_at_ms: row.fetch(1)
          )
        end
      end

      def insert(grant)
        @adapter.__send__(:transaction, operation: 'approval.grant.insert') do |txn|
          txn.execute('approval.grant.insert', <<~SQL, grant_binds(grant))
            INSERT INTO tamoz_approval_grants
              (key, scope, session_id, policy_rev, created_at_ms, expires_at_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(key, scope, session_id, policy_rev) DO NOTHING
          SQL
        end
        nil
      end

      def delete_by_session(session_id)
        deleted = nil
        @adapter.__send__(:transaction, operation: 'approval.grant.delete_by_session') do |txn|
          txn.execute('approval.grant.delete_by_session', <<~SQL, [session_id])
            DELETE FROM tamoz_approval_grants WHERE session_id = ?
          SQL
          deleted = txn.changes
        end
        deleted
      end

      private

      def grant_binds(grant)
        [
          Approval::Grant.key_text(grant.key),
          grant.scope.to_s,
          grant.session_id,
          grant.policy_rev,
          grant.created_at_ms,
          grant.expires_at_ms
        ]
      end
    end
  end
end
