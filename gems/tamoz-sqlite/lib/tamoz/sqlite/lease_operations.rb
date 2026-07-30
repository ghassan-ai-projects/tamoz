# frozen_string_literal: true

module Tamoz
  module SQLite
    module LeaseOperations
      private

      def acquire_lease(thread_id:, namespace:, owner_id:, ttl:)
        expires_at_ms = nil
        fence = nil
        transaction(operation: "lease.acquire") do |tx|
          now = backend_time(tx, "lease.acquire.time")
          tx.execute(
            "lease.acquire.thread",
            <<~SQL,
              INSERT INTO tamoz_threads(
                thread_id, tombstone_id, created_at_ms, updated_at_ms
              )
              VALUES (?, NULL, ?, ?)
              ON CONFLICT(thread_id) DO NOTHING
            SQL
            [thread_id, now, now]
          )
          thread = tx.first(
            "lease.acquire.thread_state",
            "SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?",
            [thread_id]
          )
          raise CheckpointConflictError, "thread is tombstoned" if thread&.fetch(0)

          tx.execute(
            "lease.acquire.namespace",
            <<~SQL,
              INSERT INTO tamoz_namespaces(
                thread_id, namespace, active_checkpoint_id,
                next_checkpoint_sequence, next_request_sequence,
                lease_owner_id, lease_fence, lease_expires_at_ms,
                greatest_backend_time_ms, created_at_ms, updated_at_ms
              )
              VALUES (?, ?, NULL, 0, 0, NULL, 0, NULL, ?, ?, ?)
              ON CONFLICT(thread_id, namespace) DO NOTHING
            SQL
            [thread_id, namespace, now, now, now]
          )
          row = namespace_lease_row(tx, thread_id, namespace, "lease.acquire.row")
          guard_backend_clock!(row.fetch(3), now)
          current_owner = row.fetch(0)
          current_expiry = row.fetch(2)
          if current_owner && current_expiry && current_expiry > now
            raise CheckpointConflictError,
                  "thread namespace already has an unexpired lease"
          end

          fence = row.fetch(1) + 1
          expires_at_ms = now + (ttl * 1_000).ceil
          tx.execute(
            "lease.acquire.update",
            <<~SQL,
              UPDATE tamoz_namespaces
              SET lease_owner_id = ?,
                  lease_fence = ?,
                  lease_expires_at_ms = ?,
                  greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
            SQL
            [owner_id, fence, expires_at_ms, now, now, thread_id, namespace]
          )
          raise CheckpointConflictError, "lease acquisition lost" unless tx.changes == 1
        end
        LeaseRecord.new(
          thread_id:,
          namespace:,
          owner_id:,
          fence:,
          expires_at_ms:,
          ttl:
        )
      end

      def validate_lease(lease)
        expires_at_ms = nil
        transaction(operation: "lease.validate") do |tx|
          now = backend_time(tx, "lease.validate.time")
          row = validate_lease_in_transaction!(
            tx,
            lease,
            now:,
            label: "lease.validate"
          )
          expires_at_ms = row.fetch(2)
          tx.execute(
            "lease.validate.clock",
            <<~SQL,
              UPDATE tamoz_namespaces
              SET greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
            SQL
            [now, now, lease.thread_id, lease.namespace]
          )
        end
        lease.with(expires_at_ms:)
      end

      def renew_lease(lease)
        expires_at_ms = nil
        transaction(operation: "lease.renew") do |tx|
          now = backend_time(tx, "lease.renew.time")
          validate_lease_in_transaction!(tx, lease, now:, label: "lease.renew")
          expires_at_ms = now + (lease.ttl * 1_000).ceil
          tx.execute(
            "lease.renew.update",
            <<~SQL,
              UPDATE tamoz_namespaces
              SET lease_expires_at_ms = ?,
                  greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
                AND lease_owner_id = ? AND lease_fence = ?
            SQL
            [
              expires_at_ms, now, now, lease.thread_id, lease.namespace,
              lease.owner_id, lease.fence
            ]
          )
          raise LeaseLostError, "lease renewal lost ownership" unless tx.changes == 1
        end
        lease.with(expires_at_ms:)
      end

      def release_lease(lease)
        transaction(operation: "lease.release") do |tx|
          now = backend_time(tx, "lease.release.time")
          row = namespace_lease_row(
            tx,
            lease.thread_id,
            lease.namespace,
            "lease.release.row"
          )
          guard_backend_clock!(row.fetch(3), now)
          tx.execute(
            "lease.release.update",
            <<~SQL,
              UPDATE tamoz_namespaces
              SET lease_owner_id = NULL,
                  lease_expires_at_ms = NULL,
                  greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
                AND lease_owner_id = ? AND lease_fence = ?
            SQL
            [
              now, now, lease.thread_id, lease.namespace,
              lease.owner_id, lease.fence
            ]
          )
        end
        true
      rescue LeaseLostError, CheckpointConflictError
        false
      end

      def validate_lease_in_transaction!(tx, lease, now:, label:)
        thread = tx.first(
          "#{label}.thread",
          "SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?",
          [lease.thread_id]
        )
        raise LeaseLostError, "lease thread no longer exists" unless thread
        raise LeaseLostError, "lease thread is tombstoned" if thread.fetch(0)

        row = namespace_lease_row(
          tx,
          lease.thread_id,
          lease.namespace,
          "#{label}.row"
        )
        guard_backend_clock!(row.fetch(3), now)
        unless row.fetch(0) == lease.owner_id &&
               row.fetch(1) == lease.fence &&
               row.fetch(2) &&
               row.fetch(2) > now
          raise LeaseLostError, "lease is expired or fenced by another owner"
        end

        row
      end

      def namespace_lease_row(tx, thread_id, namespace, label)
        row = tx.first(
          label,
          <<~SQL,
            SELECT lease_owner_id, lease_fence, lease_expires_at_ms,
                   greatest_backend_time_ms
            FROM tamoz_namespaces
            WHERE thread_id = ? AND namespace = ?
          SQL
          [thread_id, namespace]
        )
        raise LeaseLostError, "thread namespace does not exist" unless row

        row
      end

      def backend_time(tx, label)
        value = tx.scalar(label, Wire::BACKEND_TIME_SQL)
        unless value.is_a?(Integer) && !value.negative?
          raise ClockRollbackError, "SQLite backend time is invalid"
        end

        value
      end

      def guard_backend_clock!(greatest, now)
        tolerance = limits.clock_rollback_tolerance_ms
        return if now + tolerance >= greatest

        raise ClockRollbackError,
              "SQLite backend clock moved backward beyond #{tolerance}ms"
      end
    end
  end
end
