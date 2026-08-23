# frozen_string_literal: true

require 'json'
require 'tamoz/approval'

module Tamoz
  module SQLite
    # SQLite implementation of the Tamoz::Approval::DecisionLog port
    # (approval-policy-redesign ADR §2.5). Structural fields stay cleartext;
    # argv/targets arrive as digests from the engine. Appends are idempotent
    # on decision_id — a graph-node retry never double-writes, and an append
    # that disagrees with the recorded decision is a defect, not a retry.
    class ApprovalDecisionLog < Approval::DecisionLog
      DECISION_COLUMNS = 'decision_id, session_id, tool, verb, tier, rule_id, verdict, ' \
                         'reason, evidence, policy_rev, argv_digest, targets_digest, ' \
                         'grant_scopes, grant_key'.freeze

      # Decision identity + minted grant = cols 0..4, resolution = cols 5..9.
      RESOLUTION_SELECT = <<~SQL.freeze
        SELECT session_id, policy_rev, grant_key,
               grant_created_at_ms, grant_expires_at_ms, verdict,
               actor_evidence, answer, resolved_scope, resolved_at_ms
        FROM tamoz_approval_decisions WHERE decision_id = ?
      SQL

      def initialize(adapter:, clock: -> { Time.now })
        @adapter = adapter
        @clock = clock
      end

      def append(record)
        @adapter.__send__(:transaction, operation: 'approval.decision.append') do |txn|
          existing = txn.first('approval.decision.append.existing', <<~SQL, [record.fetch(:decision_id)])
            SELECT #{DECISION_COLUMNS} FROM tamoz_approval_decisions WHERE decision_id = ?
          SQL
          if existing
            unless same_decision?(existing, record)
              raise Approval::ConflictingResolutionError,
                    "decision #{record.fetch(:decision_id)} already logged with different content"
            end

            next nil
          end

          txn.execute('approval.decision.append', <<~SQL, append_binds(record))
            INSERT INTO tamoz_approval_decisions (
              #{DECISION_COLUMNS}, created_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          nil
        end
      end

      def lookup(decision_id)
        @adapter.__send__(:read, operation: 'approval.decision.lookup') do |txn|
          row = txn.first('approval.decision.lookup', <<~SQL, [decision_id])
            SELECT #{DECISION_COLUMNS} FROM tamoz_approval_decisions WHERE decision_id = ?
          SQL
          row && record_from_row(row)
        end
      end

      def record_resolution(decision_id:, answer:, scope:, actor_evidence:, grant:)
        @adapter.__send__(:transaction, operation: 'approval.decision.resolve') do |txn|
          txn.execute('approval.decision.resolve', <<~SQL, resolution_binds(answer, scope, actor_evidence, grant, now_ms, decision_id))
            UPDATE tamoz_approval_decisions
            SET answer = ?, resolved_scope = ?, actor_evidence = ?,
                resolved_at_ms = ?, grant_created_at_ms = ?, grant_expires_at_ms = ?
            WHERE decision_id = ? AND answer IS NULL
          SQL
          if txn.changes.positive?
            next { answer: answer, scope: scope, actor_evidence: actor_evidence, grant: grant }
          end

          row = txn.first('approval.decision.resolve.replay', RESOLUTION_SELECT, [decision_id])
          raise Approval::UnknownDecisionError, "no decision #{decision_id}" unless row

          unless row.fetch(7) == answer.to_s && row.fetch(8) == scope&.to_s
            raise Approval::ConflictingResolutionError,
                  "decision #{decision_id} already resolved as #{row.fetch(7)}/#{row.fetch(8)}"
          end

          resolution_from_row(row)
        end
      end

      def lookup_resolution(decision_id)
        @adapter.__send__(:read, operation: 'approval.decision.resolution') do |txn|
          row = txn.first('approval.decision.resolution', RESOLUTION_SELECT, [decision_id])
          row && resolution_from_row(row)
        end
      end

      private

      def same_decision?(row, record)
        fields_from_row(row) == fields_from_record(record)
      end

      def fields_from_record(record)
        [
          record.fetch(:session_id), record.fetch(:tool), record.fetch(:verb),
          record.fetch(:tier), record.fetch(:rule_id), record.fetch(:verdict),
          record.fetch(:reason), record.fetch(:evidence), record.fetch(:policy_rev),
          record.fetch(:argv_digest), record.fetch(:targets_digest),
          scopes_text(record[:grant_scopes]), key_text_or_nil(record[:grant_key])
        ]
      end

      def fields_from_row(row)
        [
          row.fetch(1), row.fetch(2), row.fetch(3),
          row.fetch(4), row.fetch(5), row.fetch(6),
          row.fetch(7), row.fetch(8), row.fetch(9),
          row.fetch(10), row.fetch(11), row.fetch(12), row.fetch(13)
        ]
      end

      # The replayed resolve returns the originally recorded grant,
      # reconstructed from the resolution columns.
      def resolution_from_row(row)
        return nil if row.nil? || row.fetch(7).nil?

        {
          answer: row.fetch(7).to_sym,
          scope: row.fetch(8)&.to_sym,
          actor_evidence: row.fetch(6)&.to_sym,
          grant: grant_from_row(row)
        }
      end

      def record_from_row(row)
        {
          decision_id: row.fetch(0),
          session_id: row.fetch(1),
          tool: row.fetch(2),
          verb: row.fetch(3),
          tier: row.fetch(4),
          rule_id: row.fetch(5),
          verdict: row.fetch(6),
          evidence: row.fetch(8),
          policy_rev: row.fetch(9),
          argv_digest: row.fetch(10),
          targets_digest: row.fetch(11),
          decision: decision_from_row(row)
        }
      end

      def decision_from_row(row)
        Approval::Decision.new(
          id: row.fetch(0),
          verdict: row.fetch(6).to_sym,
          reason: row.fetch(7),
          rule_id: row.fetch(5),
          tier: row.fetch(4).to_sym,
          grant_offer: grant_offer_from_row(row),
          required_evidence: row.fetch(8)&.to_sym,
          policy_rev: row.fetch(9),
          session_id: row.fetch(1)
        )
      end

      def grant_offer_from_row(row)
        scopes_json = row.fetch(12)
        return nil unless scopes_json

        Approval::GrantOffer.new(
          scopes: JSON.parse(scopes_json).map(&:to_sym),
          key: row.fetch(13) ? JSON.parse(row.fetch(13), symbolize_names: true) : {}
        )
      end

      def grant_from_row(row)
        return nil unless row.fetch(7) == 'approve'

        Approval::Grant.new(
          key: row.fetch(2) ? JSON.parse(row.fetch(2), symbolize_names: true) : {},
          scope: row.fetch(8).to_sym,
          session_id: row.fetch(0),
          policy_rev: row.fetch(1),
          created_at_ms: row.fetch(3),
          expires_at_ms: row.fetch(4)
        )
      end

      def scopes_text(scopes)
        JSON.generate(scopes.map(&:to_s)) if scopes
      end

      def key_text_or_nil(key)
        Approval::Grant.key_text(key) if key
      end

      def append_binds(record)
        [
          record.fetch(:decision_id), record.fetch(:session_id), record.fetch(:tool),
          record.fetch(:verb), record.fetch(:tier), record.fetch(:rule_id),
          record.fetch(:verdict), record.fetch(:reason), record.fetch(:evidence),
          record.fetch(:policy_rev), record.fetch(:argv_digest), record.fetch(:targets_digest),
          scopes_text(record[:grant_scopes]), key_text_or_nil(record[:grant_key]), now_ms
        ]
      end

      def resolution_binds(answer, scope, actor_evidence, grant, resolved_at_ms, decision_id)
        [
          answer.to_s, scope&.to_s, actor_evidence&.to_s,
          resolved_at_ms, grant&.created_at_ms, grant&.expires_at_ms, decision_id
        ]
      end

      def now_ms
        (@clock.call.to_f * 1000).to_i
      end
    end
  end
end
