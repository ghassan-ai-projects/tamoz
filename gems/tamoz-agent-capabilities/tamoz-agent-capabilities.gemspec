# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/capabilities/version'

TamozGemspec.build(
  name: 'tamoz-agent-capabilities',
  version: Tamoz::Agent::Capabilities::VERSION,
  summary: 'Capability bridge for Tamoz agents',
  description: 'The capability surface of a Tamoz agent: local tools, ' \
               'governed MCP sources, and the durable child-task capability ' \
               'bound into one sealed catalog by CapabilityBinding, with the ' \
               'MCP source builder and its governed browser/database adapters.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Agent::Capabilities::VERSION}"],
    ['tamoz-mcp', "= #{Tamoz::Agent::Capabilities::VERSION}"],
    ['tamoz-agent-kernel', "= #{Tamoz::Agent::Capabilities::VERSION}"],
    ['tamoz-tools', "= #{Tamoz::Agent::Capabilities::VERSION}"]
  ]
)
