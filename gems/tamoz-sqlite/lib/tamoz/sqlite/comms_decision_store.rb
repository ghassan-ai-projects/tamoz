# frozen_string_literal: true

require 'time'

module Tamoz
  module SQLite
    # Durable decision store for channel and CLI approvals (design §9, plan
    # slice A/C). Implements the structural Tamoz::Comms::DecisionStore
    # contract WITHOUT referencing the contract gem (dependency rule 9):
    # wire-form hashes in, wire-form hashes out. The integration layer that
    # loads both verifies the CONTRACT_VERSION pair.
    #
    # Rows live in tamoz_comms_decisions (MIGRATION_6) so every transition is
    # a compare-and-set UPDATE and — critically — the gateway's consume_prompt
    # can insert a decision and consume its prompt in ONE transaction (design
    # §13). An expired claim lease releases the record for crash recovery.
    # The wire/row mapping is a fixed column table; the size and parameter
    # metrics measure the mapping vocabulary, not a choice to overload.
    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Naming/MethodParameterName -- `ms` and `wire` are the
    #   mapping unit vocabulary.
    class CommsDecisionStore
      CONTRACT_VERSION = 1

      def initialize(adapter:)
        @adapter = adapter
      end

      def insert_decision(wire)
        @adapter.__send__(:transaction, operation: 'comms.decision.insert') do |txn|
          insert_decision_in_transaction!(txn, wire)
        end
      end

      # The transaction-scoped insert: the gateway's consume_prompt writes its
      # decision in the SAME transaction as the prompt consumption (design §13).
      def insert_decision_in_transaction!(txn, wire)
        existing = txn.first('comms.decision.insert.existing', <<~SQL, [wire.fetch('decision_id')])
          SELECT 1 FROM tamoz_comms_decisions WHERE decision_id = ?
        SQL
        return :duplicate if existing

        txn.execute('comms.decision.insert', <<~SQL, decision_binds(wire))
          INSERT INTO tamoz_comms_decisions (
            decision_id, thread_id, occurrence_id, interrupt_digest,
            direction, actor_kind, actor_id, source,
            decided_at_ms, expires_at_ms, status,
            claim_owner, claim_fence, claim_expires_at_ms, consumed_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        :created
      end

      # Newest-wins: a later operator decision on the SAME question supersedes
      # an earlier one (the old one stays as durable evidence but is never
      # consumed). A claimed record whose lease has expired is treated as
      # pending — the crash-before-submission recovery path.
      def pending_decision_for(thread_id:, occurrence_id:, interrupt_digest:, now:)
        @adapter.__send__(:read, operation: 'comms.decision.pending') do |txn|
          row = txn.first('comms.decision.pending',
                          <<~SQL, [thread_id, occurrence_id, interrupt_digest, now_ms(now), now_ms(now)])
                            SELECT #{select_columns} FROM tamoz_comms_decisions
                            WHERE thread_id = ? AND occurrence_id = ? AND interrupt_digest = ?
                              AND expires_at_ms > ?
                              AND (status = 'pending' OR (status = 'claimed' AND claim_expires_at_ms <= ?))
                            ORDER BY decided_at_ms DESC LIMIT 1
                          SQL
          row && wire_from_row(row)
        end
      end

      def claim_decision(decision_id:, owner:, fence:, claim_expires_at:, now:)
        claim_expires_ms = now_ms(claim_expires_at)
        @adapter.__send__(:transaction, operation: 'comms.decision.claim') do |txn|
          missing = txn.first('comms.decision.claim.exists', <<~SQL, [decision_id])
            SELECT 1 FROM tamoz_comms_decisions WHERE decision_id = ?
          SQL
          next :missing unless missing

          txn.execute('comms.decision.claim', <<~SQL, [owner, fence, claim_expires_ms, decision_id, now_ms(now)])
            UPDATE tamoz_comms_decisions
            SET status = 'claimed', claim_owner = ?, claim_fence = ?,
                claim_expires_at_ms = ?
            WHERE decision_id = ?
              AND (status = 'pending' OR (status = 'claimed' AND claim_expires_at_ms <= ?))
          SQL
          txn.changes == 1 ? :claimed : :not_claimable
        end
      end

      def consume_decision(decision_id:, now:)
        @adapter.__send__(:transaction, operation: 'comms.decision.consume') do |txn|
          txn.execute('comms.decision.consume', <<~SQL, [now_ms(now), decision_id])
            UPDATE tamoz_comms_decisions
            SET status = 'consumed', consumed_at_ms = ?
            WHERE decision_id = ? AND status = 'claimed'
          SQL
          next :consumed if txn.changes == 1

          status = txn.scalar('comms.decision.consume.state', <<~SQL, [decision_id])
            SELECT status FROM tamoz_comms_decisions WHERE decision_id = ?
          SQL
          if status
            status == 'consumed' ? :consumed : :not_consumable
          else
            :missing
          end
        end
      end

      def each_decision(thread_id:, limit: 500)
        @adapter.__send__(:read, operation: 'comms.decision.each') do |txn|
          rows = txn.rows('comms.decision.each', <<~SQL, [thread_id, limit])
            SELECT #{select_columns} FROM tamoz_comms_decisions
            WHERE thread_id = ? ORDER BY decided_at_ms DESC LIMIT ?
          SQL
          rows.map { |row| wire_from_row(row) }
        end
      end

      DECISION_COLUMNS = %w[
        decision_id thread_id occurrence_id interrupt_digest direction actor_kind
        actor_id source decided_at_ms expires_at_ms status claim_owner claim_fence
        claim_expires_at_ms consumed_at_ms
      ].freeze

      def select_columns = DECISION_COLUMNS.join(', ')

      def now_ms(now)
        raise ArgumentError, 'now must be a Time' unless now.is_a?(Time)

        (now.utc.to_r * 1000).to_i
      end

      def decision_binds(wire)
        [
          wire.fetch('decision_id'), wire.fetch('thread_id'), wire.fetch('occurrence_id'),
          wire.fetch('interrupt_digest'), wire.fetch('direction'), wire.fetch('actor_kind'),
          wire.fetch('actor_id'), wire.fetch('source'),
          now_ms(Time.parse(wire.fetch('decided_at'))), now_ms(Time.parse(wire.fetch('expires_at'))),
          wire.fetch('status'),
          wire['claim_owner'], wire['claim_fence'],
          wire['claim_expires_at'] && now_ms(Time.parse(wire['claim_expires_at'])),
          wire['consumed_at'] && now_ms(Time.parse(wire['consumed_at']))
        ]
      end

      def wire_from_row(row)
        values = DECISION_COLUMNS.zip(row).to_h
        {
          'decision_id' => values.fetch('decision_id'),
          'thread_id' => values.fetch('thread_id'),
          'occurrence_id' => values.fetch('occurrence_id'),
          'interrupt_digest' => values.fetch('interrupt_digest'),
          'direction' => values.fetch('direction'),
          'actor_kind' => values.fetch('actor_kind'),
          'actor_id' => values.fetch('actor_id'),
          'source' => values.fetch('source'),
          'decided_at' => wire_time(values.fetch('decided_at_ms')),
          'expires_at' => wire_time(values.fetch('expires_at_ms')),
          'status' => values.fetch('status'),
          'claim_owner' => values['claim_owner'],
          'claim_fence' => values['claim_fence'],
          'claim_expires_at' => values['claim_expires_at_ms'] && wire_time(values['claim_expires_at_ms']),
          'consumed_at' => values['consumed_at_ms'] && wire_time(values['consumed_at_ms'])
        }
      end

      def wire_time(ms)
        Time.at(ms / 1000.0).utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize
# rubocop:enable Naming/MethodParameterName
