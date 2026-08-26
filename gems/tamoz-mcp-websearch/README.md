# tamoz-mcp-websearch

Governed operator-side websearch egress for Tamoz MCP. The package preserves
the `Tamoz::Mcp::Websearch` namespace and owns the HTTP adapter, egress policy,
and egress circuit.

```ruby
require "tamoz/mcp/websearch"
```

The adapter is operator-supplied. Tamoz itself never makes an outbound call.
The deterministic fixture path is plumbing and governance evidence; it is not
evidence of real-provider intelligence.

This gem depends exactly on the repository lockstep `tamoz-mcp` and
`tamoz-core` packages. It does not depend on the agent, CLI, evals, or MCP SDK
directly.
