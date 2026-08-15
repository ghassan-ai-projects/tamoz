# frozen_string_literal: true

module Tamoz
  module SQLite
    class Adapter
      include LeaseOperations

      attr_reader :path, :limits, :pool, :kernel, :notifier, :pid, :store

      def checkpoint_protocol_version = Tamoz::Graph::CHECKPOINT_PROTOCOL_VERSION
      def durable? = true

      def bind_graph(checkpoint_codec:)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        CheckpointStore.new(adapter: self, checkpoint_codec:)
      end

      # P13-A: the durable ScheduleStore over this adapter. `checkpoint_store`
      # must be this adapter's bound graph checkpointer (the shared enqueue
      # primitive is a CheckpointStore method).
      def bind_schedule_store(checkpoint_store)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        ScheduleStore.new(adapter: self, checkpoints: checkpoint_store)
      end

      # Slice A/C: the durable decision store (design §9) — rows live in
      # tamoz_comms_decisions so the gateway can consume a prompt and insert
      # its decision in one transaction.
      def bind_comms_decision_store
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        CommsDecisionStore.new(adapter: self)
      end

      # Slice C: the channel store (design §13) — admission shares the request
      # inbox enqueue seam, so poll → admit → enqueue lands in the same file.
      def bind_comms_store(checkpoints = nil)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        CommsStore.new(adapter: self, checkpoints:)
      end

      def bind_verification_store(clock: -> { Time.now })
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        VerificationStore.new(adapter: self, clock:)
      end

      # P3: the durable verified artifact store (tenant-scoped, rehash on
      # admission + resolve).
      def bind_artifact_store(tenant:)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        ArtifactStore.new(adapter: self, tenant:)
      end

      def bind_durable_subscriber_store(tenant:)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        DurableSubscriberStore.new(adapter: self, tenant:)
      end

      def bind_approval_receipt_store(tenant:)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        ApprovalReceiptStore.new(adapter: self, tenant:)
      end

      def initialize(
        path:,
        limits: Limits.new,
        repair_permissions: false,
        fault_injector: nil,
        state_codec: StateCodec.new,
        store_protection: nil,
        notifier: Tamoz.configuration.notifier
      )
        @database_file = DatabaseFile.new(path:)
        @path = @database_file.path
        @limits = limits
        unless limits.is_a?(Limits)
          raise ConfigurationError, "limits must be a Tamoz::SQLite::Limits value"
        end
        unless repair_permissions == true || repair_permissions == false
          raise ConfigurationError, "repair_permissions must be true or false"
        end
        unless notifier.respond_to?(:instrument)
          raise ConfigurationError, "notifier must respond to instrument"
        end

        @notifier = notifier
        @pid = Process.pid
        @fault_injector = fault_injector || ->(_point, _metadata) {}
        unless @fault_injector.respond_to?(:call)
          raise ConfigurationError, "fault_injector must respond to call"
        end

        @database_file.prepare!(repair_permissions:)
        Migrator.new(
          path: @path,
          limits:,
          fault_injector: @fault_injector
        ).migrate!
        @database_file.verify!(repair_permissions:)
        @pool = ConnectionPool.new(path: @path, limits:)
        @kernel = DatabaseKernel.new(
          pool:,
          limits:,
          fault_injector: @fault_injector
        )
        @backup = Backup.new(
          database_file: @database_file,
          pool:,
          limits:,
          fault_injector: @fault_injector
        )
        @store = Store.new(
          adapter: self,
          state_codec:,
          protection: store_protection
        )
        @thread_tombstone = ThreadTombstone.new(adapter: self)
        @thread_purge = ThreadPurge.new(adapter: self)
        @database_file.verify_sidecars!
      rescue Exception # rubocop:disable Lint/RescueException
        @pool&.close
        raise
      end

      def close
        ensure_process!
        pool.close
      end

      def closed?
        pool.closed?
      end

      def stats
        ensure_process!
        pool.stats.merge(
          "path" => path,
          "pid" => pid
        ).freeze
      end

      def integrity_check
        ensure_process!
        result = kernel.read(operation: "integrity.check") do |tx|
          integrity = tx.rows("integrity.check", "PRAGMA integrity_check")
          foreign_keys = tx.rows(
            "integrity.foreign_keys",
            "PRAGMA foreign_key_check"
          )
          schema_version = tx.scalar(
            "integrity.schema_version",
            "PRAGMA user_version"
          )
          {
            "integrity" => integrity.flatten,
            "foreign_key_violations" => foreign_keys,
            "schema_version" => schema_version
          }
        end
        unless result.fetch("integrity") == ["ok"] &&
               result.fetch("foreign_key_violations").empty? &&
               result.fetch("schema_version") == Migrator::CURRENT_VERSION
          raise IntegrityError, "SQLite integrity check failed"
        end

        result.merge("ok" => true).freeze
      end

      def backup(destination)
        ensure_process!
        @backup.call(destination)
      end

      def tombstone_thread(thread_id:, expected_tips:, authorization:)
        ensure_process!
        @thread_tombstone.call(
          thread_id:,
          expected_tips:,
          authorization:
        )
      end

      def purge_thread(tombstone_id:)
        ensure_process!
        @thread_purge.call(tombstone_id:)
      end

      def deletion_receipt(tombstone_id:)
        ensure_process!
        @thread_purge.receipt(tombstone_id:)
      end

      private

      attr_reader :fault_injector

      def transaction(**arguments, &block)
        ensure_process!
        kernel.transaction(**arguments, &block)
      end

      def read(**arguments, &block)
        ensure_process!
        kernel.read(**arguments, &block)
      end

      def ensure_process!
        return if Process.pid == pid

        raise ClosedError,
              "SQLite adapter cannot be reused after fork; construct one in the child"
      end
    end
  end
end
