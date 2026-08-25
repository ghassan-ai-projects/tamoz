# frozen_string_literal: true

require 'pathname'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Owns secure database-file creation, permission checks, and sidecar validation.
    # :reek:ControlParameter :reek:FeatureEnvy :reek:ManualDispatch
    # :reek:MissingSafeMethod :reek:TooManyStatements :reek:UncommunicativeVariableName
    # The boolean repair policy and bang methods are the explicit secure-file API;
    # the remaining helpers keep refusal order visible at the filesystem boundary.
    class DatabaseFile
      FILE_MODE = 0o600
      UNSAFE_MODE_MASK = 0o077

      attr_reader :path

      def initialize(path:)
        @path = normalize_path(path)
      end

      def prepare!(repair_permissions:)
        verify_parent!
        if existing?
          verify!(repair_permissions:)
          return
        end

        create_database_file!
        verify!(repair_permissions: false)
      rescue Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::ELOOP => e
        raise PermissionError.new('cannot create secure SQLite database'), cause: e
      end

      def verify!(repair_permissions:)
        stat = File.lstat(path)
        verify_identity!(stat)
        repair_permissions!(stat, repair_permissions:)
        true
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => e
        raise PermissionError.new('cannot inspect SQLite database file'), cause: e
      end

      def verify_sidecars!
        %W[#{path}-wal #{path}-shm].each do |sidecar|
          next unless File.exist?(sidecar)

          stat = File.lstat(sidecar)
          raise PermissionError, 'SQLite sidecar permissions are unsafe' unless secure_regular_file?(stat)
        end
      end

      def secure_mode
        FILE_MODE
      end

      def create_secure_temporary!(target)
        File.open(target, exclusive_write_flags, FILE_MODE) { nil }
        stat = File.lstat(target)
        raise PermissionError, 'backup temporary file is unsafe' unless secure_regular_file?(stat)
      end

      def verify_backup!(target)
        database = ::SQLite3::Database.new(
          target,
          readonly: true,
          strict: true,
          results_as_hash: false
        )
        integrity = database.execute('PRAGMA integrity_check').flatten
        foreign_keys = database.execute('PRAGMA foreign_key_check')
        unless integrity == ['ok'] && foreign_keys.empty?
          raise IntegrityError, 'SQLite backup failed integrity validation'
        end

        Migrator.verify_connection!(database)
        true
      ensure
        database&.close unless database&.closed?
      end

      private

      def verify_parent!
        parent = File.dirname(path)
        raise PermissionError, 'SQLite parent directory does not exist' unless File.directory?(parent)
      end

      def existing?
        File.exist?(path) || File.symlink?(path)
      end

      def create_database_file!
        File.open(path, exclusive_write_flags, FILE_MODE) { nil }
        File.chmod(FILE_MODE, path)
      end

      def exclusive_write_flags
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags
      end

      def verify_identity!(stat)
        raise PermissionError, 'SQLite path must not be a symlink' if stat.symlink?
        raise PermissionError, 'SQLite path must be a regular file' unless stat.file?
        return unless Process.respond_to?(:uid) && stat.uid != Process.uid

        raise PermissionError, 'SQLite file is not owned by the current user'
      end

      def secure_regular_file?(stat)
        stat.file? && !stat.symlink? &&
          stat.mode.nobits?(UNSAFE_MODE_MASK)
      end

      def repair_permissions!(stat, repair_permissions:)
        unsafe = stat.mode & UNSAFE_MODE_MASK
        return unless unsafe.positive?
        return File.chmod(FILE_MODE, path) if repair_permissions

        raise PermissionError,
              'SQLite file permissions expose group or other access'
      end

      def normalize_path(value)
        text = SafeText.normalize(
          value.respond_to?(:to_path) ? value.to_path : value,
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

      private_constant :FILE_MODE, :UNSAFE_MODE_MASK
    end

    private_constant :DatabaseFile
  end
end
