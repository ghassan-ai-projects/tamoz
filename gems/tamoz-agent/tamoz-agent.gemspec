# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/agent/version"

TamozGemspec.build(
  name: "tamoz-agent",
  version: Tamoz::Agent::VERSION,
  summary: "Deliberative agent runtime for Tamoz",
  description: "Plan, review, execute, verify, remember, and improve over Tamoz graphs.",
  dependencies: [["tamoz-graph", "= #{Tamoz::Agent::VERSION}"]]
)
