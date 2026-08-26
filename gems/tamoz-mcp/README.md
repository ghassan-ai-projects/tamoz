# tamoz-mcp

Governed MCP client/host for Tamoz (P10), built on the official `mcp` Ruby SDK.

```ruby
require "tamoz/mcp"

config = Tamoz::Mcp::ServerConfig.new(
  server_id: "test-server",
  transport: :stdio,
  command: "/usr/local/bin/ruby",
  arguments: ["script/mcp_test_server"],
  working_directory: Dir.pwd
)

config.describe # exact command/argv/env-name preview; never env values
```

`ServerConfig` is the immutable, fail-closed admission configuration for one MCP
server: transport, exact argv, environment allowlist, credential references (names
only), protocol range, admitted primitives, and budgets. Everything is validated at
construction with typed `Tamoz::Mcp::ValidationError` rejections; nothing is spawned
here. Catalog compilation, invocation, supervision, and elicitation arrive in later
P10 slices per `docs/P10_MCP_PLAN.md`.

This package depends on `tamoz-core`, `tamoz-cancellation`, and the official
`mcp` gem. It never
requires `tamoz-agent`, `tamoz-sqlite`, or a model provider.
