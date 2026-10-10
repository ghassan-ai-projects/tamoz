# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Approval prompts (ADR-043): inserted inactive, activated only once their send receipt is
    # durable, and consumed once together with the decision they record.
    class CommsPrompts
      include CommsStoreRows

      PROMPT_COLUMNS = %w[
        reference_digest surface_id surface_revision thread_id occurrence_id
        interrupt_digest required_evidence correspondent_id conversation_id
        prompt_receipt status created_at_ms activated_at_ms consumed_at_ms
        expires_at_ms
      ].freeze
      def initialize(adapter:, decisions:)
        @adapter = adapter
        @decisions = decisions
      end

      # Idempotent on reference_digest.
      def insert_prompt(prompt_wire)
        transaction('comms.prompt.insert') do |txn|
          existing = txn.first('comms.prompt.insert.existing', <<~SQL, [prompt_wire.fetch('reference_digest')])
            SELECT 1 FROM tamoz_comms_approval_prompts WHERE reference_digest = ?
          SQL
          next :duplicate if existing

          txn.execute('comms.prompt.insert', <<~SQL, prompt_binds(prompt_wire))
            INSERT INTO tamoz_comms_approval_prompts (
              reference_digest, surface_id, surface_revision, thread_id,
              occurrence_id, interrupt_digest, required_evidence,
              correspondent_id, conversation_id, prompt_receipt, status,
              created_at_ms, activated_at_ms, consumed_at_ms, expires_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          :inserted
        end
      end

      # Pins the originating message receipt (contract §7.1) so a press binds to the exact message the
      # buttons were attached to; a prompt without a receipt is never activatable.
      def activate_prompt(reference_digest:, now:, receipt:)
        transaction('comms.prompt.activate') do |txn|
          status, expires_at_ms = prompt_state(txn, 'comms.prompt.activate.state', reference_digest)
          next :missing unless status
          next :expired if expires_at_ms <= now_ms(now)
          next :already_active if status == 'active'

          txn.execute('comms.prompt.activate', <<~SQL, [receipt, now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'active', prompt_receipt = ?, activated_at_ms = ?
            WHERE reference_digest = ? AND status = 'inactive'
          SQL
          txn.changes == 1 ? :activated : :not_consumable
        end
      end

      # A replayed reference can never be consumed twice, and a consumed prompt never leaves a decision
      # behind (design §9).
      def consume_prompt(reference_digest:, decision_wire:, now:)
        transaction('comms.prompt.consume') do |txn|
          status, expires_at_ms = prompt_state(txn, 'comms.prompt.consume.state', reference_digest)
          next :missing unless status
          next :expired if expires_at_ms <= now_ms(now)

          txn.execute('comms.prompt.consume', <<~SQL, [now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'consumed', consumed_at_ms = ?
            WHERE reference_digest = ? AND status = 'active'
          SQL
          next :not_consumable unless txn.changes == 1

          @decisions.insert_decision_in_transaction!(txn, decision_wire)
          :consumed
        end
      end

      def prompt(reference_digest:)
        read('comms.prompt.read') do |txn|
          row = txn.first('comms.prompt.read', <<~SQL, [reference_digest])
            SELECT #{PROMPT_COLUMNS.join(', ')} FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          row && PROMPT_COLUMNS.zip(row).to_h
        end
      end

      private

      def prompt_state(txn, label, reference_digest)
        txn.first(label, <<~SQL, [reference_digest])
          SELECT status, expires_at_ms FROM tamoz_comms_approval_prompts
          WHERE reference_digest = ?
        SQL
      end

      def prompt_binds(wire)
        [
          wire.fetch('reference_digest'), wire['surface_id'], wire['surface_revision'],
          wire.fetch('thread_id'), wire.fetch('occurrence_id'), wire.fetch('interrupt_digest'),
          wire.fetch('required_evidence'),
          wire.fetch('correspondent_id'), wire.fetch('conversation_id'), wire['prompt_receipt'],
          wire.fetch('status'), wire_time_ms(wire.fetch('created_at')),
          wire_time_ms(wire['activated_at']), wire_time_ms(wire['consumed_at']),
          wire_time_ms(wire.fetch('expires_at'))
        ]
      end
    end
  end
end
