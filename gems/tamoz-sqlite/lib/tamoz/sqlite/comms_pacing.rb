# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Delivery pacing (design §12): one durable next-allowed time per chat and per surface, so concurrent
    # drainers and a server's retry deadline share one schedule.
    class CommsPacing
      include CommsStoreRows

      GLOBAL_SCOPE = '__global__'

      def initialize(adapter:)
        @adapter = adapter
      end

      # Reserves the next send slot for one chat and the surface-wide lane; the returned delay is safe for
      # concurrent drainers.
      def reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:, global_messages_per_s:, now:)
        validate_rate!(per_chat_messages_per_s, 'per_chat_messages_per_s')
        validate_rate!(global_messages_per_s, 'global_messages_per_s')
        current_ms = now_ms(now)
        global_interval = interval_ms(global_messages_per_s)
        chat_interval = interval_ms(per_chat_messages_per_s)
        transaction('comms.outbox.pacing.reserve') do |txn|
          global_ready = [current_ms, pacing_time(txn, surface_id, GLOBAL_SCOPE)].max
          chat_ready = if conversation_id
                         [current_ms, pacing_time(txn, surface_id, conversation_id)].max
                       else
                         current_ms
                       end
          scheduled = [global_ready, chat_ready].max
          upsert_pacing!(txn, surface_id, GLOBAL_SCOPE, scheduled + global_interval)
          upsert_pacing!(txn, surface_id, conversation_id, scheduled + chat_interval) if conversation_id
          (scheduled - current_ms) / 1000.0
        end
      end

      # Persists a provider retry deadline in the pacing lane.
      def defer_delivery(surface_id:, conversation_id:, not_before:, now:)
        deadline = [now_ms(now), now_ms(not_before)].max
        transaction('comms.outbox.pacing.defer') do |txn|
          scopes = [GLOBAL_SCOPE, conversation_id].compact.uniq
          scopes.each do |scope|
            current = pacing_time(txn, surface_id, scope)
            upsert_pacing!(txn, surface_id, scope, [current, deadline].max)
          end
          :deferred
        end
      end

      private

      def validate_rate!(value, name)
        return if value.is_a?(Numeric) && value.positive?

        raise ArgumentError, "#{name} must be a positive number"
      end

      def interval_ms(rate)
        (1000.0 / rate).ceil
      end

      def pacing_time(txn, surface_id, scope)
        return 0 unless scope

        txn.scalar('comms.outbox.pacing.read', <<~SQL, [surface_id, scope]).to_i
          SELECT next_allowed_at_ms FROM tamoz_comms_delivery_pacing
          WHERE surface_id = ? AND scope = ?
        SQL
      end

      def upsert_pacing!(txn, surface_id, scope, next_allowed_at_ms)
        txn.execute('comms.outbox.pacing.upsert', <<~SQL, [surface_id, scope, next_allowed_at_ms])
          INSERT INTO tamoz_comms_delivery_pacing (surface_id, scope, next_allowed_at_ms)
          VALUES (?, ?, ?)
          ON CONFLICT(surface_id, scope) DO UPDATE SET
            next_allowed_at_ms = excluded.next_allowed_at_ms
        SQL
      end
    end
  end
end
