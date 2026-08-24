# tamoz-agent-capabilities

The capability bridge of a Tamoz agent: how local tools, governed MCP servers,
and the durable child-task capability are assembled into one sealed catalog and
dispatched. Extracted from `tamoz-agent` so the session layer and external
harnesses (CLI, evals) depend on a finished bridge instead of ungrouped runtime
files.

## Public surface

Under `Tamoz::Agent` (unchanged constant paths):

- **CapabilityBinding** — assembles the sealed capability source over a
  Toolbox, an optional MCP source, and the child-task dispatcher; resolves a
  tool name to its descriptor, catalog snapshot, and effect class.
- **McpSourceBuilder** — compiles runtime-directory MCP settings into an
  `McpCapabilitySource`, applying database/browser governance policies.
- **McpCapabilitySource** — invocation and catalog-snapshot surface over
  compiled MCP catalogs.
- **GovernedBrowserSource** / **GovernedDatabaseSource** — policy-guarded
  adapters for browser and SQL capabilities.
- **ChildTask** / **ChildTaskDispatcher** — the durable delegation value and
  its single-tool dispatcher.

`Tamoz::Agent::Capabilities::VERSION` ships in lockstep with the rest of the
monorepo (`0.1.0.alpha.1` literal per gem, hand-synced like every sibling).

## Dependencies

`tamoz-core`, `tamoz-mcp`, `tamoz-agent-kernel`, `tamoz-tools`
(CapabilityBinding constructs the tools gem's CapabilityHost/LocalDispatcher
directly). Nothing here reaches up into session, worker, or CLI code: consumers
(the runtime/worker wiring in `tamoz-agent`, the CLI, the evals harness) point
down only. The MCP gem loads lazily — its constants are touched when an MCP
source is actually built.
