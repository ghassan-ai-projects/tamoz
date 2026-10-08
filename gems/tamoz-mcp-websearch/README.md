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

It serves three tools through `script/websearch_adapter`: `search` (Brave, or a
fixture web), `read_page` (a page one of its own searches returned) and `read_url`
(any public page; Tamoz never offers it to a planner and calls it only for a URL
the user wrote or a search returned). The
pieces are `BraveSearch` (fixed endpoint, `TAMOZ_BRAVE_API_KEY`), `PageReader`
over `EgressClient`'s public reach (any public FQDN, every per-hop check kept),
`PageText` (HTML to readable text with `nokogiri`) and `FixtureWeb`.
`RecordedWeb` (a directory cache shared by runs, with `SearchLedger`'s hard cap
on live searches) sits in front of any of them, and the declaration's
`EgressCircuit` opens after the declared consecutive-failure threshold.

This gem depends on the repository lockstep `tamoz-mcp` and `tamoz-core`
packages and on `nokogiri`. It does not depend on the agent, CLI, evals, or
MCP SDK directly.
