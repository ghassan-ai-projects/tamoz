# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/graph/version"

TamozGemspec.build(
  name: "tamoz-graph",
  version: Tamoz::Graph::VERSION,
  summary: "Deterministic checkpointed graph runtime for Tamoz",
  description: "Bulk-synchronous in-memory graph execution with explicit interrupts and streaming.",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Graph::VERSION}"],
    ["zeitwerk", "~> 2.6"]
  ]
)
