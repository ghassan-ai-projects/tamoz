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
                         'step_scope, grant_scopes, grant_key'.freeze

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
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          binds = resolution_binds(answer: answer, scope: scope, actor_evidence: actor_evidence,
                                   grant: grant, resolved_at_ms: now_ms, decision_id: decision_id)
          txn.execute('approval.decision.resolve', <<~SQL, binds)
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

      SWITCH_COLUMNS = 'switch_id, session_id, actor_id, from_rev, to_rev, profile_name, ts_ms'.freeze

      # Idempotent on the switch id. The switch identity is who/where/from/to:
      # a replayed append carries a fresh ts_ms, so the timestamp of the first
      # application is what the audit keeps.
      def record_mode_switch(id:, session_id:, actor_id:, from_rev:, to_rev:, profile_name:, ts_ms:)
        record = {
          id: id, session_id: session_id, actor_id: actor_id,
          from_rev: from_rev, to_rev: to_rev, profile_name: profile_name, ts_ms: ts_ms
        }.freeze
        @adapter.__send__(:transaction, operation: 'approval.mode_switch.record') do |txn|
          row = txn.first('approval.mode_switch.existing', <<~SQL, [id])
            SELECT #{SWITCH_COLUMNS} FROM tamoz_approval_mode_switches WHERE switch_id = ?
          SQL
          if row
            stored = switch_from_row(row)
            unless same_switch?(stored, record)
              raise Approval::ConflictingResolutionError,
                    "mode switch #{id} already recorded with different content"
            end

            next stored
          end

          txn.execute('approval.mode_switch.record', <<~SQL, [id, session_id, actor_id, from_rev, to_rev, profile_name, ts_ms])
            INSERT INTO tamoz_approval_mode_switches (#{SWITCH_COLUMNS})
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          record
        end
      end

      def latest_decision_for(session_id:, argv_digest:, targets_digest:, step_scope:)
        @adapter.__send__(:read, operation: 'approval.decision.latest_for') do |txn|
          row = txn.first('approval.decision.latest_for', <<~SQL, [session_id, argv_digest, targets_digest, step_scope])
            SELECT #{DECISION_COLUMNS} FROM tamoz_approval_decisions
            WHERE session_id = ? AND argv_digest = ? AND targets_digest = ? AND step_scope = ?
            ORDER BY created_at_ms DESC, decision_id DESC LIMIT 1
          SQL
          row && decision_from_row(row)
        end
      end

      def decision_created_at_ms(decision_id)
        @adapter.__send__(:read, operation: 'approval.decision.created_at') do |txn|
          txn.scalar(
            'approval.decision.created_at',
            'SELECT created_at_ms FROM tamoz_approval_decisions WHERE decision_id = ?',
            [decision_id]
          )&.to_i
        end
      end

      def lookup_mode_switch(id)
        @adapter.__send__(:read, operation: 'approval.mode_switch.lookup') do |txn|
          row = txn.first('approval.mode_switch.lookup', <<~SQL, [id])
            SELECT #{SWITCH_COLUMNS} FROM tamoz_approval_mode_switches WHERE switch_id = ?
          SQL
          row && switch_from_row(row)
        end
      end

      def latest_mode_switch(session_id)
        @adapter.__send__(:read, operation: 'approval.mode_switch.latest') do |txn|
          row = txn.first('approval.mode_switch.latest', <<~SQL, [session_id.to_s])
            SELECT #{SWITCH_COLUMNS} FROM tamoz_approval_mode_switches
            WHERE session_id = ? ORDER BY ts_ms DESC LIMIT 1
          SQL
          row && switch_from_row(row)
        end
      end

      private

      def same_decision?(row, record)
        fields_from_row(row) == fields_from_record(record)
      end

      def same_switch?(stored, record)
        %i[session_id actor_id from_rev to_rev profile_name].all? do |field|
          stored.fetch(field) == record.fetch(field)
        end
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

      # Identity skips step_scope (column 12): provenance, not content.
      def fields_from_row(row)
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14].map { |index| row.fetch(index) }
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
        scopes_json = row.fetch(13)
        return nil unless scopes_json

        Approval::GrantOffer.new(
          scopes: JSON.parse(scopes_json).map(&:to_sym),
          key: row.fetch(14) ? JSON.parse(row.fetch(14), symbolize_names: true) : {}
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

      def switch_from_row(row)
        {
          id: row.fetch(0),
          session_id: row.fetch(1),
          actor_id: row.fetch(2),
          from_rev: row.fetch(3),
          to_rev: row.fetch(4),
          profile_name: row.fetch(5),
          ts_ms: row.fetch(6)
        }.freeze
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
          record.fetch(:step_scope),
          scopes_text(record[:grant_scopes]), key_text_or_nil(record[:grant_key]), now_ms
        ]
      end

      def resolution_binds(answer:, scope:, actor_evidence:, grant:, resolved_at_ms:, decision_id:)
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
