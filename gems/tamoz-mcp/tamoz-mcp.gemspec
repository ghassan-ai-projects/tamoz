# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/mcp/version"
require_relative "../tamoz-core/lib/tamoz/core/version"

TamozGemspec.build(
  name: "tamoz-mcp",
  version: Tamoz::Mcp::VERSION,
  summary: "Governed MCP client/host for Tamoz",
  description: "Immutable server admission, catalog, invocation, and supervision over the official MCP SDK.",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Core::VERSION}"],
    ["mcp", "~> 1.1"]
  ]
)
