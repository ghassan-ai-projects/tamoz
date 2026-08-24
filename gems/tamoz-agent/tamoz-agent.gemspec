# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/agent/version"

TamozGemspec.build(
  name: "tamoz-agent",
  version: Tamoz::Agent::VERSION,
  summary: "Deliberative agent runtime for Tamoz",
  description: "Plan, review, execute, verify, remember, and improve over Tamoz graphs.",
  dependencies: [
    ["tamoz-agent-kernel", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-capabilities", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-memory", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-healing", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-profile", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-session", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-agent-improvement", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-tools", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-graph", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-sqlite", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-comms", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-approval", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-cancellation", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-concurrency", "= #{Tamoz::Agent::VERSION}"],
    ["tamoz-observability", "= #{Tamoz::Agent::VERSION}"],
    ["ruby_llm", "~> 1.16.0"]
  ]
)
