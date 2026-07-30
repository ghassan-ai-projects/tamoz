# frozen_string_literal: true

module Tamoz
  module SQLite
    class Error < Tamoz::Error
      include Tamoz::FatalRuntimeFailure

      CATEGORY = "sqlite"
      SAFE_MESSAGE = "Durable workflow storage is unavailable."
    end

    class BusyError < Error
      CATEGORY = "sqlite_busy"
      RETRYABLE = true
      SAFE_MESSAGE = "Durable workflow storage is busy."
    end

    class ClosedError < Error
      CATEGORY = "sqlite_closed"
      SAFE_MESSAGE = "Durable workflow storage is closed."
    end

    class PermissionError < Error
      CATEGORY = "sqlite_permission"
      SAFE_MESSAGE = "Durable workflow storage permissions are unsafe."
    end

    class MigrationError < Error
      CATEGORY = "sqlite_migration"
      SAFE_MESSAGE = "Durable workflow storage could not be migrated."
    end

    class ClockRollbackError < Error
      CATEGORY = "sqlite_clock_rollback"
      SAFE_MESSAGE = "Durable ownership stopped after a storage clock rollback."
    end

    class IntegrityError < Tamoz::CheckpointCorruptionError
      CATEGORY = "sqlite_integrity"
      SAFE_MESSAGE = "Durable workflow storage failed its integrity check."
    end
  end
end
