# frozen_string_literal: true

require 'json'

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Outbox rows read back: by status for the drainer, the delivered conversation a connection resumes
    # with, and the row a reply quotes.
    class CommsOutboxReads
      include CommsStoreRows

      OUTBOX_COLUMNS = %w[
        delivery_id surface_id conversation_id kind operation text part_index
        part_count markup reply_to journaled content_digest render_version
        expires_at_ms status claim_owner claim_fence claim_expires_at_ms
        effect_key effect_execution_id receipt created_at_ms updated_at_ms
        send_started_at_ms request_id
      ].freeze

      def initialize(adapter:)
        @adapter = adapter
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

      def delivered_messages(surface_id:, limit:)
        columns = OUTBOX_COLUMNS.map { |column| "outbox.#{column}" }.join(', ')
        read('comms.outbox.delivered') do |txn|
          recent = txn.rows('comms.outbox.delivered.recent', <<~SQL, [surface_id, limit])
            SELECT #{columns} FROM tamoz_comms_outbox AS outbox
            WHERE outbox.surface_id = ? AND outbox.status = 'succeeded'
            ORDER BY outbox.created_at_ms DESC, outbox.delivery_id DESC LIMIT ?
          SQL
          live = txn.rows('comms.outbox.delivered.live', <<~SQL, [surface_id])
            SELECT #{columns} FROM tamoz_comms_outbox AS outbox
            JOIN tamoz_comms_approval_prompts AS prompt
              ON prompt.surface_id = outbox.surface_id AND prompt.conversation_id = outbox.conversation_id
             AND prompt.status = 'active'
             AND json_extract(outbox.receipt, '$.message_id') = CAST(prompt.prompt_receipt AS INTEGER)
            WHERE outbox.surface_id = ? AND outbox.status = 'succeeded' AND outbox.kind = 'approval_request'
          SQL
          (recent + live).map { |row| OUTBOX_COLUMNS.zip(row).to_h }
                         .uniq { |row| row.fetch('delivery_id') }
                         .sort_by { |row| [row.fetch('created_at_ms'), row.fetch('delivery_id')] }
        end
      end

      def outbox_row_for_receipt(surface_id:, conversation_id:, message_id:)
        message_id = Integer(message_id, exception: false)
        return nil unless message_id&.positive?

        pattern = "%\"message_id\":#{message_id}%"
        read('comms.outbox.receipt') do |txn|
          rows = txn.rows('comms.outbox.receipt', <<~SQL, [surface_id, conversation_id, pattern])
            SELECT #{OUTBOX_COLUMNS.join(', ')} FROM tamoz_comms_outbox
            WHERE surface_id = ? AND conversation_id = ? AND status = 'succeeded'
              AND receipt LIKE ?
            ORDER BY created_at_ms DESC
          SQL
          rows.map { |row| OUTBOX_COLUMNS.zip(row).to_h }.find do |row|
            receipt = JSON.parse(row.fetch('receipt'))
            receipt.is_a?(Hash) && receipt['message_id'] == message_id
          rescue JSON::ParserError
            false
          end
        end
      end
    end
  end
end
