# frozen_string_literal: true

require "pathname"
require "securerandom"

module Tamoz
  module SQLite
    class Adapter
      include LeaseOperations

      FILE_MODE = 0o600
      UNSAFE_MODE_MASK = 0o077

      attr_reader :path, :limits, :pool, :kernel, :notifier, :pid, :store

      def checkpoint_protocol_version = Tamoz::Graph::CHECKPOINT_PROTOCOL_VERSION
      def durable? = true

      def bind_graph(checkpoint_codec:)
        ensure_process!
        raise ClosedError, "SQLite adapter is closed" if closed?

        CheckpointStore.new(adapter: self, checkpoint_codec:)
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
        @path = normalize_path(path)
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

        prepare_file!(repair_permissions:)
        Migrator.new(
          path: @path,
          limits:,
          fault_injector: @fault_injector
        ).migrate!
        verify_file!(repair_permissions:)
        @pool = ConnectionPool.new(path: @path, limits:)
        @kernel = DatabaseKernel.new(
          pool:,
          limits:,
          fault_injector: @fault_injector
        )
        @store = Store.new(
          adapter: self,
          state_codec:,
          protection: store_protection
        )
        verify_sidecar_permissions!
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
               result.fetch("schema_version") == 1
          raise IntegrityError, "SQLite integrity check failed"
        end

        result.merge("ok" => true).freeze
      end

      def backup(destination)
        ensure_process!
        destination_path = normalize_path(destination)
        if destination_path == path
          raise ConfigurationError, "backup destination must differ from source"
        end
        if File.exist?(destination_path) || File.symlink?(destination_path)
          raise PermissionError, "backup destination already exists"
        end
        parent = File.dirname(destination_path)
        unless File.directory?(parent)
          raise PermissionError, "backup parent directory does not exist"
        end

        temporary = File.join(
          parent,
          ".#{File.basename(destination_path)}.tamoz-#{SecureRandom.hex(12)}.tmp"
        )
        create_secure_empty_file!(temporary)
        destination_database = nil
        backup_handle = nil
        pages = 0
        begin
          destination_database = ::SQLite3::Database.new(
            temporary,
            readwrite: true,
            strict: true,
            results_as_hash: false
          )
          deadline = Tamoz::Clock.monotonic.now + limits.operation_timeout
          pool.with_connection(deadline:) do |source_database|
            backup_handle = ::SQLite3::Backup.new(
              destination_database,
              "main",
              source_database,
              "main"
            )
            loop do
              if Tamoz::Clock.monotonic.now >= deadline
                raise BusyError, "SQLite online backup exceeded its total deadline"
              end
              fault_injector.call(
                :before_backup_step,
                {"operation" => "backup", "destination" => destination_path}.freeze
              )
              result = backup_handle.step(128)
              pages = backup_handle.pagecount
              fault_injector.call(
                :after_backup_step,
                {"operation" => "backup", "destination" => destination_path}.freeze
              )
              break if result == ::SQLite3::Constants::ErrorCode::DONE
              next if result == ::SQLite3::Constants::ErrorCode::OK
              if [
                ::SQLite3::Constants::ErrorCode::BUSY,
                ::SQLite3::Constants::ErrorCode::LOCKED
              ].include?(result) && Tamoz::Clock.monotonic.now < deadline
                sleep([limits.retry_base_delay, 0.001].max)
                next
              end
              raise BusyError, "SQLite online backup could not make progress"
            end
          end
          backup_handle.finish
          backup_handle = nil
          destination_database.close
          destination_database = nil
          verify_backup_file!(temporary)
          File.chmod(FILE_MODE, temporary)
          fault_injector.call(
            :before_backup_publish,
            {"operation" => "backup", "destination" => destination_path}.freeze
          )
          File.rename(temporary, destination_path)
          fault_injector.call(
            :after_backup_publish,
            {"operation" => "backup", "destination" => destination_path}.freeze
          )
          stat = File.stat(destination_path)
          BackupReport.new(
            source: path,
            destination: destination_path.freeze,
            pages:,
            bytes: stat.size,
            schema_version: 1,
            created_at_ms: (Time.now.to_r * 1_000).to_i
          )
        rescue ::SQLite3::Exception => error
          ExceptionMapper.raise_mapped(error, operation: "online backup")
        rescue Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::EEXIST => error
          raise PermissionError.new("cannot publish secure SQLite backup"), cause: error
        ensure
          begin
            backup_handle&.finish
          rescue ::SQLite3::Exception
            # Preserve the operation's primary failure.
          end
          destination_database&.close unless destination_database&.closed?
          File.delete(temporary) if temporary && File.exist?(temporary)
        end
      end

      def tombstone_thread(thread_id:, expected_tips:, authorization:)
        ensure_process!
        thread = Wire.identity(thread_id, name: "thread id")
        unless authorization.is_a?(DeletionAuthorization)
          raise ConfigurationError,
                "tombstone requires a Tamoz::SQLite::DeletionAuthorization"
        end
        normalized_tips = normalize_expected_tips(expected_tips)
        authorization_payload = deletion_authorization_payload(authorization)
        tombstone_id = SecureRandom.uuid.freeze
        report = nil

        transaction(operation: "thread.tombstone") do |tx|
          now = backend_time(tx, "thread.tombstone.time")
          existing = tx.first(
            "thread.tombstone.existing",
            <<~SQL,
              SELECT t.tombstone_id, t.expected_tips, t.authorization, t.report,
                     t.report_digest, t.created_at_ms, t.purge_after_ms
              FROM tamoz_thread_tombstones t
              WHERE t.thread_id = ?
            SQL
            [thread]
          )
          if existing
            unless existing.fetch(1) == JSON.generate(normalized_tips) &&
                   existing.fetch(2) == JSON.generate(authorization_payload)
              raise CheckpointConflictError,
                    "thread already has a different tombstone intent"
            end
            report = materialize_deletion_report(
              existing.fetch(3),
              digest: existing.fetch(4)
            )
            next
          end

          thread_row = tx.first(
            "thread.tombstone.thread",
            "SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?",
            [thread]
          )
          raise CheckpointConflictError, "thread does not exist" unless thread_row
          raise CheckpointConflictError, "thread is already tombstoned" if thread_row.fetch(0)

          namespaces = tx.rows(
            "thread.tombstone.namespaces",
            <<~SQL,
              SELECT namespace, active_checkpoint_id, lease_fence,
                     lease_owner_id, lease_expires_at_ms
              FROM tamoz_namespaces
              WHERE thread_id = ?
              ORDER BY namespace COLLATE BINARY
            SQL
            [thread]
          )
          actual_tips = namespaces.to_h { |row| [row.fetch(0), row.fetch(1)] }
          unless actual_tips == normalized_tips
            raise CheckpointConflictError, "thread checkpoint tips changed"
          end
          namespaces.each do |row|
            next unless row.fetch(3) && row.fetch(4) && row.fetch(4) > now
            unless authorization.lease_fences.fetch(row.fetch(0), nil) == row.fetch(2)
              raise CheckpointConflictError,
                    "live lease requires its exact current fence"
            end
          end

          unresolved = tx.rows(
            "thread.tombstone.effects",
            <<~SQL,
              SELECT effect_key, current_attempt
              FROM tamoz_effects
              WHERE thread_id = ?
                AND status IN ('prepared', 'running', 'unknown', 'reconcile')
              ORDER BY effect_key
            SQL
            [thread]
          )
          unresolved.each do |effect_key, attempt_number|
            unless authorization.effect_decisions.fetch(effect_key, nil) == "abandon"
              raise CheckpointConflictError,
                    "unresolved effect requires explicit abandonment"
            end
            tx.execute(
              "thread.tombstone.effect_attempt",
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'abandoned', completed_at_ms = COALESCE(completed_at_ms, ?)
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running', 'unknown')
              SQL
              [now, effect_key, attempt_number]
            )
            tx.execute(
              "thread.tombstone.effect",
              <<~SQL,
                UPDATE tamoz_effects
                SET status = 'abandoned', updated_at_ms = ?
                WHERE effect_key = ?
                  AND status IN ('prepared', 'running', 'unknown', 'reconcile')
              SQL
              [now, effect_key]
            )
            append_deletion_effect_transition!(
              tx,
              effect_key:,
              attempt_number:,
              authorization:,
              now:
            )
          end

          counts = deletion_counts(tx, thread, "thread.tombstone")
          purge_after = now + (limits.deletion_retention * 1_000).ceil
          report_hash = {
            "thread_id" => thread,
            "tombstone_id" => tombstone_id,
            "status" => "active",
            "counts" => counts,
            "abandoned_effect_keys" => unresolved.map(&:first),
            "created_at_ms" => now,
            "purge_after_ms" => purge_after
          }
          report_bytes = JSON.generate(report_hash)
          report_digest = Wire.digest(
            report_bytes,
            domain: "tamoz.sqlite.tombstone_report"
          )
          tx.execute(
            "thread.tombstone.insert",
            <<~SQL,
              INSERT INTO tamoz_thread_tombstones(
                thread_id, tombstone_id, expected_tips, status, effect_policy,
                authorization, report, report_digest, created_at_ms, purge_after_ms
              )
              VALUES (?, ?, ?, 'active', 'explicit', ?, ?, ?, ?, ?)
            SQL
            [
              thread, tombstone_id, Wire.blob(JSON.generate(normalized_tips)),
              Wire.blob(JSON.generate(authorization_payload)),
              Wire.blob(report_bytes), report_digest, now, purge_after
            ]
          )
          tx.execute(
            "thread.tombstone.block",
            <<~SQL,
              UPDATE tamoz_threads
              SET tombstone_id = ?, updated_at_ms = ?
              WHERE thread_id = ? AND tombstone_id IS NULL
            SQL
            [tombstone_id, now, thread]
          )
          raise CheckpointConflictError, "thread tombstone lost" unless tx.changes == 1
          report = materialize_deletion_report(report_bytes, digest: report_digest)
        end
        report
      end

      def purge_thread(tombstone_id:)
        ensure_process!
        id = Wire.identity(tombstone_id, name: "tombstone id")
        receipt = nil
        transaction(operation: "thread.purge") do |tx|
          now = backend_time(tx, "thread.purge.time")
          existing_receipt = tx.first(
            "thread.purge.receipt",
            <<~SQL,
              SELECT thread_id_digest, report, report_digest, purged_at_ms
              FROM tamoz_deletion_receipts
              WHERE tombstone_id = ?
            SQL
            [id]
          )
          if existing_receipt
            receipt = materialize_deletion_receipt(id, existing_receipt)
            next
          end
          row = tx.first(
            "thread.purge.tombstone",
            <<~SQL,
              SELECT thread_id, report, report_digest, purge_after_ms
              FROM tamoz_thread_tombstones
              WHERE tombstone_id = ? AND status = 'active'
            SQL
            [id]
          )
          raise CheckpointConflictError, "active tombstone does not exist" unless row
          thread = row.fetch(0)
          if row.fetch(3) && now < row.fetch(3)
            raise CheckpointConflictError, "thread retention window has not expired"
          end
          unresolved = tx.scalar(
            "thread.purge.unresolved",
            <<~SQL,
              SELECT COUNT(*)
              FROM tamoz_effects
              WHERE thread_id = ?
                AND status IN ('prepared', 'running', 'unknown', 'reconcile')
            SQL
            [thread]
          )
          if unresolved.positive?
            raise CheckpointConflictError, "thread still has unresolved effects"
          end

          counts = deletion_counts(tx, thread, "thread.purge")
          Wire.verify_digest!(
            row.fetch(1),
            row.fetch(2),
            domain: "tamoz.sqlite.tombstone_report"
          )
          report_hash = JSON.parse(row.fetch(1), create_additions: false)
          final_report = JSON.generate(
            report_hash.merge(
              "status" => "purged",
              "purged_at_ms" => now,
              "purged_counts" => counts
            )
          )
          report_digest = Wire.digest(
            final_report,
            domain: "tamoz.sqlite.deletion_report"
          )
          thread_digest = Wire.digest(
            thread,
            domain: "tamoz.sqlite.deleted_thread"
          )
          tx.execute(
            "thread.purge.insert_receipt",
            <<~SQL,
              INSERT INTO tamoz_deletion_receipts(
                tombstone_id, thread_id_digest, report, report_digest, purged_at_ms
              )
              VALUES (?, ?, ?, ?, ?)
            SQL
            [id, thread_digest, Wire.blob(final_report), report_digest, now]
          )
          tx.execute(
            "thread.purge.delete",
            "DELETE FROM tamoz_threads WHERE thread_id = ? AND tombstone_id = ?",
            [thread, id]
          )
          raise CheckpointConflictError, "thread purge lost" unless tx.changes == 1
          receipt = DeletionReceipt.new(
            thread_id_digest: thread_digest.freeze,
            tombstone_id: id,
            report_digest: report_digest.freeze,
            purged_at_ms: now,
            counts: counts.freeze
          )
        end
        receipt
      end

      def deletion_receipt(tombstone_id:)
        ensure_process!
        id = Wire.identity(tombstone_id, name: "tombstone id")
        row = read(operation: "thread.deletion_receipt") do |tx|
          tx.first(
            "thread.deletion_receipt",
            <<~SQL,
              SELECT thread_id_digest, report, report_digest, purged_at_ms
              FROM tamoz_deletion_receipts
              WHERE tombstone_id = ?
            SQL
            [id]
          )
        end
        row && materialize_deletion_receipt(id, row)
      end

      private

      attr_reader :fault_injector

      def normalize_expected_tips(value)
        raise ConfigurationError, "expected_tips must be a Hash" unless value.is_a?(Hash)

        value.each_with_object({}) do |(namespace, checkpoint_id), result|
          encoded = Wire.namespace(namespace)
          id = checkpoint_id &&
               Wire.identity(checkpoint_id, name: "expected checkpoint id")
          raise ConfigurationError, "duplicate expected namespace" if result.key?(encoded)

          result[encoded] = id
        end.sort.to_h.freeze
      end

      def deletion_authorization_payload(authorization)
        {
          "actor" => authorization.actor,
          "reason_digest" => Wire.digest(
            authorization.reason,
            domain: "tamoz.sqlite.deletion_reason"
          ),
          "effect_decisions" => authorization.effect_decisions.sort.to_h,
          "lease_fences" => authorization.lease_fences.sort.to_h
        }.freeze
      end

      def deletion_counts(tx, thread, prefix)
        {
          "namespaces" => tx.scalar(
            "#{prefix}.count.namespaces",
            "SELECT COUNT(*) FROM tamoz_namespaces WHERE thread_id = ?",
            [thread]
          ),
          "checkpoints" => tx.scalar(
            "#{prefix}.count.checkpoints",
            "SELECT COUNT(*) FROM tamoz_checkpoints WHERE thread_id = ?",
            [thread]
          ),
          "requests" => tx.scalar(
            "#{prefix}.count.requests",
            "SELECT COUNT(*) FROM tamoz_requests WHERE thread_id = ?",
            [thread]
          ),
          "effects" => tx.scalar(
            "#{prefix}.count.effects",
            "SELECT COUNT(*) FROM tamoz_effects WHERE thread_id = ?",
            [thread]
          )
        }.freeze
      end

      def append_deletion_effect_transition!(
        tx,
        effect_key:,
        attempt_number:,
        authorization:,
        now:
      )
        index = tx.scalar(
          "thread.tombstone.effect_transition_index",
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_effect_transitions
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
        evidence = JSON.generate(
          "reason_digest" => Wire.digest(
            authorization.reason,
            domain: "tamoz.sqlite.deletion_reason"
          )
        )
        tx.execute(
          "thread.tombstone.effect_transition",
          <<~SQL,
            INSERT INTO tamoz_effect_transitions(
              effect_key, transition_index, transition, attempt_number,
              actor, evidence, created_at_ms
            )
            VALUES (?, ?, 'deletion.abandon', ?, ?, ?, ?)
          SQL
          [
            effect_key, index, attempt_number, authorization.actor,
            Wire.blob(evidence), now
          ]
        )
      end

      def materialize_deletion_report(bytes, digest:)
        Wire.verify_digest!(
          bytes,
          digest,
          domain: "tamoz.sqlite.tombstone_report"
        )
        value = JSON.parse(bytes, create_additions: false, max_nesting: 16)
        counts = value.fetch("counts")
        status = case value.fetch("status")
                 when "active" then :active
                 when "purged" then :purged
                 else
                   raise IntegrityError, "deletion report status is invalid"
                 end
        DeletionReport.new(
          thread_id: value.fetch("thread_id").dup.freeze,
          tombstone_id: value.fetch("tombstone_id").dup.freeze,
          status:,
          namespace_count: counts.fetch("namespaces"),
          checkpoint_count: counts.fetch("checkpoints"),
          request_count: counts.fetch("requests"),
          effect_count: counts.fetch("effects"),
          abandoned_effect_keys: value.fetch("abandoned_effect_keys").map do |key|
            key.dup.freeze
          end.freeze,
          created_at_ms: value.fetch("created_at_ms"),
          purge_after_ms: value.fetch("purge_after_ms")
        )
      rescue JSON::ParserError, KeyError, TypeError => error
        raise IntegrityError.new("deletion report is invalid"), cause: error
      end

      def materialize_deletion_receipt(id, row)
        Wire.verify_digest!(
          row.fetch(1),
          row.fetch(2),
          domain: "tamoz.sqlite.deletion_report"
        )
        value = JSON.parse(row.fetch(1), create_additions: false, max_nesting: 16)
        DeletionReceipt.new(
          thread_id_digest: row.fetch(0).dup.freeze,
          tombstone_id: id,
          report_digest: row.fetch(2).dup.freeze,
          purged_at_ms: row.fetch(3),
          counts: value.fetch("purged_counts").freeze
        )
      rescue JSON::ParserError, KeyError, TypeError => error
        raise IntegrityError.new("deletion receipt is invalid"), cause: error
      end

      def transaction(**arguments, &block)
        ensure_process!
        kernel.transaction(**arguments, &block)
      end

      def read(**arguments, &block)
        ensure_process!
        kernel.read(**arguments, &block)
      end

      def normalize_path(value)
        text = SafeText.normalize(
          value.respond_to?(:to_path) ? value.to_path : value,
          name: "SQLite path",
          max_bytes: 4_096,
          error_class: ConfigurationError
        )
        if text == ":memory:" || text.start_with?("file:")
          raise ConfigurationError,
                "SQLite memory databases and URI filenames are unsupported"
        end

        Pathname.new(text).expand_path.to_s.freeze
      end

      def prepare_file!(repair_permissions:)
        parent = File.dirname(path)
        unless File.directory?(parent)
          raise PermissionError, "SQLite parent directory does not exist"
        end

        if File.exist?(path) || File.symlink?(path)
          verify_file!(repair_permissions:)
          return
        end

        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, FILE_MODE) {}
        File.chmod(FILE_MODE, path)
        verify_file!(repair_permissions: false)
      rescue Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::ELOOP => error
        raise PermissionError.new("cannot create secure SQLite database"), cause: error
      end

      def create_secure_empty_file!(target)
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(target, flags, FILE_MODE) {}
        stat = File.lstat(target)
        unless stat.file? && !stat.symlink? &&
               (stat.mode & UNSAFE_MODE_MASK).zero?
          raise PermissionError, "backup temporary file is unsafe"
        end
      end

      def verify_backup_file!(target)
        database = ::SQLite3::Database.new(
          target,
          readonly: true,
          strict: true,
          results_as_hash: false
        )
        integrity = database.execute("PRAGMA integrity_check").flatten
        foreign_keys = database.execute("PRAGMA foreign_key_check")
        unless integrity == ["ok"] && foreign_keys.empty?
          raise IntegrityError, "SQLite backup failed integrity validation"
        end
        Migrator.verify_connection!(database)
        true
      ensure
        database&.close unless database&.closed?
      end

      def verify_file!(repair_permissions:)
        stat = File.lstat(path)
        raise PermissionError, "SQLite path must not be a symlink" if stat.symlink?
        raise PermissionError, "SQLite path must be a regular file" unless stat.file?
        if Process.respond_to?(:uid) && stat.uid != Process.uid
          raise PermissionError, "SQLite file is not owned by the current user"
        end

        unsafe = stat.mode & UNSAFE_MODE_MASK
        if unsafe.positive?
          if repair_permissions
            File.chmod(FILE_MODE, path)
          else
            raise PermissionError,
                  "SQLite file permissions expose group or other access"
          end
        end
        true
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => error
        raise PermissionError.new("cannot inspect SQLite database file"), cause: error
      end

      def verify_sidecar_permissions!
        %W[#{path}-wal #{path}-shm].each do |sidecar|
          next unless File.exist?(sidecar)

          stat = File.lstat(sidecar)
          unless stat.file? && !stat.symlink? &&
                 (stat.mode & UNSAFE_MODE_MASK).zero?
            raise PermissionError, "SQLite sidecar permissions are unsafe"
          end
        end
      end

      def ensure_process!
        return if Process.pid == pid

        raise ClosedError,
              "SQLite adapter cannot be reused after fork; construct one in the child"
      end

      private_constant :FILE_MODE, :UNSAFE_MODE_MASK
    end
  end
end
