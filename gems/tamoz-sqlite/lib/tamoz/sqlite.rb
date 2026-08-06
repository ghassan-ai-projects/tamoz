# frozen_string_literal: true

require "tamoz/graph"
require "tamoz/scheduler"
require "tamoz/stream"
require "sqlite3"
require_relative "sqlite/version"
require_relative "sqlite/error"
require_relative "sqlite/limits"
require_relative "sqlite/wire"
require_relative "sqlite/boundary_registry"
require_relative "sqlite/fault_hook"
require_relative "sqlite/exception_mapper"
require_relative "sqlite/transaction"
require_relative "sqlite/connection_pool"
require_relative "sqlite/database_kernel"
require_relative "sqlite/migrator"
require_relative "sqlite/backup_report"
require_relative "sqlite/deletion"
require_relative "sqlite/prune_report"
require_relative "sqlite/lease"
require_relative "sqlite/lease_operations"
require_relative "sqlite/store"
require_relative "sqlite/circuit_store"
require_relative "sqlite/schedule_store"
require_relative "sqlite/stream_store"
require_relative "sqlite/memory_repository"
require_relative "sqlite/effect_journal"
require_relative "sqlite/checkpoint_wire"
require_relative "sqlite/checkpoint_store"
require_relative "sqlite/adapter"

module Tamoz
  module SQLite
    ROOT = File.expand_path("../../..", __dir__).freeze
  end
end
