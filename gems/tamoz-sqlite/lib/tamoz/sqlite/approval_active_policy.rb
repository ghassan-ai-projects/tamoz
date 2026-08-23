# frozen_string_literal: true

module Tamoz
  module SQLite
    # The single-row active-policy record the reload loop reads
    # (approval-policy-redesign ADR §1.5). `tamoz approve --reload` writes
    # `(policy_path, policy_rev)` only after the document validates in the CLI
    # process; workers compare this rev against their engine's each poll pass.
    class ApprovalActivePolicy
      def initialize(adapter:, clock: -> { Time.now })
        @adapter = adapter
        @clock = clock
      end

      def read
        @adapter.__send__(:read, operation: 'approval.active_policy.read') do |txn|
          row = txn.first('approval.active_policy.read', <<~SQL, [])
            SELECT policy_path, policy_rev FROM tamoz_approval_active_policy WHERE id = 1
          SQL
          row && { path: row.fetch(0), rev: row.fetch(1) }
        end
      end

      def write(path, rev)
        @adapter.__send__(:transaction, operation: 'approval.active_policy.write') do |txn|
          txn.execute('approval.active_policy.write', <<~SQL, [path, rev, now_ms])
            INSERT INTO tamoz_approval_active_policy (id, policy_path, policy_rev, updated_at_ms)
            VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              policy_path = excluded.policy_path,
              policy_rev = excluded.policy_rev,
              updated_at_ms = excluded.updated_at_ms
          SQL
        end
        nil
      end

      private

      def now_ms
        (@clock.call.to_f * 1000).to_i
      end
    end
  end
end
