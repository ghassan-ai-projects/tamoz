# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/agent/session_gem/version"

TamozGemspec.build(
  name: "tamoz-agent-session",
  version: Tamoz::Agent::SessionGem::VERSION,
  summary: "Durable deliberation session for Tamoz agents",
  description: "The deliberation loop of a Tamoz agent: the durable Session " \
               "class over its versioned records, planning context, nodes, " \
               "effects, evidence, routing, and adaptive machinery.",
  dependencies: [
    ["tamoz-agent-capabilities", "= #{Tamoz::Agent::SessionGem::VERSION}"],
    ["tamoz-agent-kernel", "= #{Tamoz::Agent::SessionGem::VERSION}"],
    ["tamoz-agent-memory", "= #{Tamoz::Agent::SessionGem::VERSION}"],
    ["tamoz-agent-profile", "= #{Tamoz::Agent::SessionGem::VERSION}"],
    ["tamoz-agent-healing", "= #{Tamoz::Agent::SessionGem::VERSION}"],
    ["tamoz-core", "= #{Tamoz::Agent::SessionGem::VERSION}"]
  ]
)
