# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # One conversation's memory: the recent transcript a turn is planned with, and the durable /new
    # generation folded into its thread identity.
    class CommsHistory
      include CommsStoreRows

      HISTORY_LIMIT = 12
      HISTORY_TEXT_CHARACTERS = 500

      def initialize(adapter:, checkpoints:)
        @adapter = adapter
        @checkpoints = checkpoints
      end

      # Oldest first. User lines are the admitted requests' task payloads (the inbound table stores
      # hashes, never text); assistant lines only the CONFIRMED terminal deliveries (invariant 11).
      # Bounded twice — `limit` entries, each truncated — because it rides into a model prompt.
      def conversation_history(surface_id:, conversation_id:, thread_id:, limit: HISTORY_LIMIT)
        scope = [surface_id, conversation_id, thread_id, limit]
        entries = recent_request_tasks(scope) + recent_terminal_deliveries(scope)
        entries.sort_by { |entry| entry.fetch(:at) }.last(limit).map do |entry|
          { 'role' => entry.fetch(:role), 'text' => entry.fetch(:text) }
        end
      end

      def conversation_generation(surface_id:, conversation_id:)
        read('comms.conversation.generation') { |txn| generation_row!(txn, surface_id, conversation_id) }
      end

      # One durable +1 per `/new`; an absent conversation raises before anything mutates.
      def bump_generation(surface_id:, conversation_id:)
        transaction('comms.conversation.bump_generation') do |txn|
          txn.execute('comms.conversation.bump_generation.update', <<~SQL, [surface_id, conversation_id])
            UPDATE tamoz_comms_conversations SET generation = generation + 1
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          unless txn.changes == 1
            raise KeyError,
                  "conversation #{conversation_id} is not bound on surface #{surface_id}"
          end

          generation_row!(txn, surface_id, conversation_id)
        end
      end

      private

      def generation_row!(txn, surface_id, conversation_id)
        row = txn.first('comms.conversation.generation.read', <<~SQL, [surface_id, conversation_id])
          SELECT generation FROM tamoz_comms_conversations
          WHERE surface_id = ? AND conversation_id = ?
        SQL
        raise KeyError, "conversation #{conversation_id} is not bound on surface #{surface_id}" unless row

        row.fetch(0)
      end

      def recent_request_tasks(scope)
        rows = read('comms.history.requests') do |txn|
          txn.rows('comms.history.requests', <<~SQL, scope)
            SELECT request_id, thread_id, created_at_ms FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ? AND thread_id = ?
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.filter_map do |request_id, thread_id, at|
          task = request_task(request_id, thread_id)
          task && { role: 'user', text: task[0, HISTORY_TEXT_CHARACTERS], at: }
        end
      end

      # A channel turn with history nests its text under the task Hash; any other non-text turn (a
      # cancel or redirect payload) has no transcript line.
      def request_task(request_id, thread_id)
        return nil unless @checkpoints

        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        task = request&.payload&.fetch('task', nil)
        task = task.fetch('text', nil) if task.is_a?(Hash)
        task.is_a?(String) ? task : nil
      end

      # Only `succeeded` rows qualify: pending, claimed, unknown and failed rows never enter a later
      # model prompt (invariant 11).
      def recent_terminal_deliveries(scope)
        rows = read('comms.history.deliveries') do |txn|
          txn.rows('comms.history.deliveries', <<~SQL, scope)
            SELECT text, created_at_ms FROM tamoz_comms_outbox
            WHERE surface_id = ? AND conversation_id = ? AND journaled = 1
              AND request_id IN (SELECT request_id FROM tamoz_requests WHERE thread_id = ?)
              AND status = 'succeeded'
              AND kind IN ('answer', 'failed', 'stopped', 'blocked') AND part_index = 0
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.map { |text, at| { role: 'assistant', text: text[0, HISTORY_TEXT_CHARACTERS], at: } }
      end
    end
  end
end
