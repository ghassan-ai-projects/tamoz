# frozen_string_literal: true

require 'securerandom'
require 'pathname'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Copies a live database through SQLite's online-backup API and publishes it securely.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:ManualDispatch
    # :reek:TooManyMethods :reek:TooManyStatements :reek:UncommunicativeVariableName
    # :reek:UtilityFunction -- the helper set mirrors the backup protocol's ordered
    # resource lifecycle; collapsing it would hide cleanup and publish boundaries.
    class Backup
      def initialize(database_file:, pool:, limits:, fault_injector:)
        @database_file = database_file
        @pool = pool
        @limits = limits
        @fault_injector = fault_injector
      end

      def call(destination)
        destination_path = normalize_destination(destination)
        temporary = temporary_path(destination_path)
        database_file.create_secure_temporary!(temporary)
        begin
          pages = copy_backup(temporary, destination_path)
          publish_backup(temporary, destination_path, pages:)
        rescue ::SQLite3::Exception => e
          ExceptionMapper.raise_mapped(e, operation: 'online backup')
        rescue Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::EEXIST => e
          raise PermissionError.new('cannot publish secure SQLite backup'), cause: e
        ensure
          File.delete(temporary) if temporary && File.exist?(temporary)
        end
      end

      private

      attr_reader :database_file, :pool, :limits, :fault_injector

      def normalize_destination(destination)
        destination_path = database_file_path(destination)
        raise ConfigurationError, 'backup destination must differ from source' if destination_path == database_file.path
        if File.exist?(destination_path) || File.symlink?(destination_path)
          raise PermissionError, 'backup destination already exists'
        end

        parent = File.dirname(destination_path)
        raise PermissionError, 'backup parent directory does not exist' unless File.directory?(parent)

        destination_path
      end

      def database_file_path(destination)
        text = SafeText.normalize(
          destination.respond_to?(:to_path) ? destination.to_path : destination,
          name: 'SQLite path',
          max_bytes: 4_096,
          error_class: ConfigurationError
        )
        if text == ':memory:' || text.start_with?('file:')
          raise ConfigurationError,
                'SQLite memory databases and URI filenames are unsupported'
        end

        Pathname.new(text).expand_path.to_s.freeze
      end

      def temporary_path(destination_path)
        File.join(
          File.dirname(destination_path),
          ".#{File.basename(destination_path)}.tamoz-#{SecureRandom.hex(12)}.tmp"
        )
      end

      def copy_backup(temporary, destination_path)
        destination_database = nil
        backup_handle = nil
        destination_database = open_database(temporary)
        deadline = monotonic_now + limits.operation_timeout
        pages = pool.with_connection(deadline:) do |source_database|
          backup_handle = ::SQLite3::Backup.new(
            destination_database,
            'main',
            source_database,
            'main'
          )
          step_backup(backup_handle, destination_path, deadline:)
        end
        backup_handle.finish
        backup_handle = nil
        destination_database = close_destination(destination_database)
        pages
      ensure
        finish_backup(backup_handle)
        destination_database&.close unless destination_database&.closed?
      end

      def open_database(temporary)
        ::SQLite3::Database.new(
          temporary,
          readwrite: true,
          strict: true,
          results_as_hash: false
        )
      end

      def close_destination(database)
        database.close
        nil
      end

      def step_backup(handle, destination_path, deadline:)
        pages = 0
        loop do
          raise_backup_timeout(deadline)
          result, pages = perform_backup_step(handle, destination_path)
          break if result == ::SQLite3::Constants::ErrorCode::DONE
          next if result == ::SQLite3::Constants::ErrorCode::OK
          next if retry_backup_step?(result, deadline)

          raise BusyError, 'SQLite online backup could not make progress'
        end
        pages
      end

      def perform_backup_step(handle, destination_path)
        fault_injector.call(:before_backup_step, backup_metadata(destination_path))
        result = handle.step(128)
        pages = handle.pagecount
        fault_injector.call(:after_backup_step, backup_metadata(destination_path))
        [result, pages]
      end

      def backup_metadata(destination_path)
        { 'operation' => 'backup', 'destination' => destination_path }.freeze
      end

      def raise_backup_timeout(deadline)
        return unless monotonic_now >= deadline

        raise BusyError, 'SQLite online backup exceeded its total deadline'
      end

      def retry_backup_step?(result, deadline)
        retryable = [
          ::SQLite3::Constants::ErrorCode::BUSY,
          ::SQLite3::Constants::ErrorCode::LOCKED
        ].include?(result)
        return false unless retryable && monotonic_now < deadline

        sleep([limits.retry_base_delay, 0.001].max)
        true
      end

      def finish_backup(handle)
        handle&.finish
      rescue ::SQLite3::Exception
        # Preserve the operation's primary failure.
      end

      def publish_backup(temporary, destination_path, pages:)
        database_file.verify_backup!(temporary)
        File.chmod(database_file.secure_mode, temporary)
        fault_injector.call(:before_backup_publish, backup_metadata(destination_path))
        File.rename(temporary, destination_path)
        fault_injector.call(:after_backup_publish, backup_metadata(destination_path))
        build_report(destination_path, pages)
      end

      def build_report(destination_path, pages)
        stat = File.stat(destination_path)
        BackupReport.new(
          source: database_file.path,
          destination: destination_path.freeze,
          pages:,
          bytes: stat.size,
          schema_version: Migrator::CURRENT_VERSION,
          created_at_ms: (Time.now.to_r * 1_000).to_i
        )
      end

      def monotonic_now
        Tamoz::Clock.monotonic.now
      end
    end

    private_constant :Backup
  end
end
