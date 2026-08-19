# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/evals/version"
require_relative "../tamoz-core/lib/tamoz/core/version"
require_relative "../tamoz-agent/lib/tamoz/agent/version"
require_relative "../tamoz-sqlite/lib/tamoz/sqlite/version"
require_relative "../tamoz-mcp/lib/tamoz/mcp/version"

TamozGemspec.build(
  name: "tamoz-evals",
  version: Tamoz::Evals::VERSION,
  summary: "Evaluation and release evidence for Tamoz",
  description: "Canonical artifacts, conformance suites, comparison, and release gates.",
  executable: "tamoz-eval",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Core::VERSION}"],
    ["tamoz-agent", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-sqlite", "= #{Tamoz::SQLite::VERSION}"],
    ["tamoz-mcp", "= #{Tamoz::Mcp::VERSION}"]
  ]
)
