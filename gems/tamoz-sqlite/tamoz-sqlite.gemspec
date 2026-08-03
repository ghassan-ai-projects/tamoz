# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/sqlite/version"

TamozGemspec.build(
  name: "tamoz-sqlite",
  version: Tamoz::SQLite::VERSION,
  summary: "SQLite persistence for Tamoz",
  description: "SQLite checkpoints, request inbox, effects, leases, and application storage.",
  dependencies: [
    ["tamoz-graph", "= #{Tamoz::SQLite::VERSION}"],
    ["tamoz-scheduler", "= #{Tamoz::SQLite::VERSION}"],
    ["sqlite3", "~> 2.9"]
  ]
)
