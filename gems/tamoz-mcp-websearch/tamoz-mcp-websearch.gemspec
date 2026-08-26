# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/mcp/websearch/version'
require_relative '../tamoz-core/lib/tamoz/core/version'

TamozGemspec.build(
  name: 'tamoz-mcp-websearch',
  version: Tamoz::Mcp::Websearch::VERSION,
  summary: 'Governed operator-side websearch egress for Tamoz MCP',
  description: 'Bounded, policy-enforced websearch egress with redirect, credential, and circuit controls.',
  dependencies: [
    ['tamoz-mcp', "= #{Tamoz::Core::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Core::VERSION}"]
  ]
)
