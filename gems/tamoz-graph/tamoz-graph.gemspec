# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/graph/version"

TamozGemspec.build(
  name: "tamoz-graph",
  version: Tamoz::Graph::VERSION,
  summary: "Deterministic durable graph runtime for Tamoz",
  description: "Checkpointed graph execution with explicit interrupt and effect semantics.",
  dependencies: [["tamoz-core", "= #{Tamoz::Graph::VERSION}"]]
)
