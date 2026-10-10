# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Update-stream polling (design §13): one fenced poller per stream, and the durable offset it
    # advances only after the polled prefix is durable.
    class CommsPolling
      include CommsStoreRows

      POLL_COLUMNS = %w[
        stream_id surface_id next_offset poller_owner_id poller_fence
        poller_expires_at_ms updated_at_ms
      ].freeze
      def initialize(adapter:)
        @adapter = adapter
      end

      # A live lease is not claimable by a second poller; an expired lease is recoverable.
      def acquire_poller_lease(surface_id:, stream_id:, lease:, ttl_s:, now:)
        transaction('comms.poll.lease') do |txn|
          current = txn.first('comms.poll.lease.current', <<~SQL, [stream_id])
            SELECT poller_owner_id, poller_fence, poller_expires_at_ms
            FROM tamoz_comms_poll_state WHERE stream_id = ?
          SQL
          next :not_acquirable if current && current[2] && current[2] > now_ms(now) && current[0] != lease.owner

          upsert_poller!(txn, [stream_id, surface_id, lease.owner, lease.fence, now_ms(now) + (ttl_s * 1000),
                               now_ms(now)])
          :acquired
        end
      end

      # Never regresses: an offset behind the stored one is :behind, and a nil candidate (an empty
      # poll prefix) is :unchanged — it must never clobber the durable offset.
      def persist_next_offset(surface_id:, stream_id:, next_offset:, now:)
        transaction('comms.poll.offset') do |txn|
          next :unchanged if next_offset.nil?

          stored = txn.first('comms.poll.offset.stored', <<~SQL, [stream_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE stream_id = ?
          SQL
          next :behind if stored && !stored[0].nil? && stored[0] >= next_offset

          txn.execute('comms.poll.offset.upsert', <<~SQL, [stream_id, surface_id, next_offset, now_ms(now)])
            INSERT INTO tamoz_comms_poll_state (
              stream_id, surface_id, next_offset, updated_at_ms
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(stream_id) DO UPDATE SET
              next_offset = excluded.next_offset, updated_at_ms = excluded.updated_at_ms
          SQL
          :persisted
        end
      end

      # The durable next_offset for one update stream (nil when never persisted).
      def poll_offset(stream_id:)
        read('comms.poll.offset.read') do |txn|
          txn.scalar('comms.poll.offset.read', <<~SQL, [stream_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE stream_id = ?
          SQL
        end
      end

      # Releases only a lease that is still ours, so a crashed gateway's lease expires on its own.
      def release_poller_lease(stream_id:, lease:)
        transaction('comms.poll.release') do |txn|
          txn.execute('comms.poll.release', <<~SQL, [stream_id, lease.owner, lease.fence])
            UPDATE tamoz_comms_poll_state
            SET poller_owner_id = NULL, poller_fence = NULL, poller_expires_at_ms = NULL
            WHERE stream_id = ? AND poller_owner_id = ? AND poller_fence = ?
          SQL
          :released
        end
      end

      def poll_state(stream_id:)
        read('comms.poll.state') do |txn|
          row = txn.first('comms.poll.state', <<~SQL, [stream_id])
            SELECT #{POLL_COLUMNS.join(', ')} FROM tamoz_comms_poll_state
            WHERE stream_id = ?
          SQL
          row && POLL_COLUMNS.zip(row).to_h
        end
      end

      private

      def upsert_poller!(txn, binds)
        txn.execute('comms.poll.lease.upsert', <<~SQL, binds)
          INSERT INTO tamoz_comms_poll_state (
            stream_id, surface_id, poller_owner_id, poller_fence,
            poller_expires_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(stream_id) DO UPDATE SET
            poller_owner_id = excluded.poller_owner_id,
            poller_fence = excluded.poller_fence,
            poller_expires_at_ms = excluded.poller_expires_at_ms,
            updated_at_ms = excluded.updated_at_ms
        SQL
      end
    end
  end
end
