# MCP — a server being down costs a call, never a session

- **A failure at session build must not be memoized for the process's life.** On 2026-10-06 the
  Telegram worker started while the ALMS host was unreachable; `McpSourceBuilder#build` raised on that
  one server, `WorkerRuntime` memoized a session with no MCP source at all, and websearch and ALMS were
  both gone until a restart. Build each server on its own, plan from its stored catalog
  (`McpCatalogStore`), and rebuild a source that is missing a server
  (`WorkerRuntime#retry_missing_mcp_servers`).
- **A tool the model cannot see does not exist.** The work loop listed only local tools and probes, so
  configured MCP tools never reached Telegram even when connected. When a capability is admitted,
  check the surface the live harness renders (`WorkContext#surface_tools`), not only the capability
  registry.
