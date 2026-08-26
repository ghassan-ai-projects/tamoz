# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "../tamoz-evals/lib/tamoz/evals/version"
require_relative "../tamoz-core/lib/tamoz/core/version"
require_relative "../tamoz-agent/lib/tamoz/agent/version"
require_relative "../tamoz-sqlite/lib/tamoz/sqlite/version"
require_relative "../tamoz-mcp/lib/tamoz/mcp/version"
require_relative "../tamoz-graph/lib/tamoz/graph/version"
require_relative "../tamoz-tools/lib/tamoz/tools/version"
require_relative "../tamoz-comms/lib/tamoz/comms/version"
require_relative "../tamoz-agent-cli/lib/tamoz/agent/cli/version"

TamozGemspec.build(
  name: "tamoz-evals-runner",
  version: Tamoz::Evals::VERSION,
  summary: "Tamoz evaluation harness and benchmark runner",
  description: "Explicit-input harnesses, benchmarks, scorecards, and treatment runners.",
  executable: "tamoz-eval-runner",
  dependencies: [
    ["tamoz-evals", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-core", "= #{Tamoz::Core::VERSION}"],
    ["tamoz-agent", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-kernel", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-agent-cli", "= #{Tamoz::Agent::CLI::VERSION}"],
    ["tamoz-agent-capabilities", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-session", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-memory", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-agent-profile", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-agent-healing", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-agent-improvement", "= #{Tamoz::Evals::VERSION}"],
    ["tamoz-sqlite", "= #{Tamoz::SQLite::VERSION}"],
    ["tamoz-mcp", "= #{Tamoz::Mcp::VERSION}"],
    ["tamoz-graph", "= #{Tamoz::Graph::VERSION}"],
    ["tamoz-tools", "= #{Tamoz::Tools::VERSION}"],
    ["tamoz-comms", "= #{Tamoz::Comms::VERSION}"]
  ]
)
