# MCP and web availability — plan

Found 2026-10-08 from the Telegram chat of 2026-10-06: the agent had no memory, no MCP tools and no web.

## Causes

1. Memory: `sources.memory` was absent from the runtime config (operator config, fixed in place).
2. MCP: `McpSourceBuilder#build` compiled every server's catalog live and raised on the first failure, so
   one unreachable server removed every MCP tool; the worker then memoized the MCP-less session for its
   whole life. A resumed turn whose server set changed stops at the catalog pin.
3. MCP in chat: the work loop (the harness Telegram runs) shows only local tools and probes; generic
   MCP tools never reach its surface.
4. Web: `sources.websearch` was absent; ordinary turns have no web tools (only deep-research children);
   `read_page` reads only a URL its own search returned, so a link the user pastes cannot be read.

## Design

**S1 — a catalog is needed to plan, a connection only to call.**
- `Tamoz::Mcp::Catalog#to_h` / `.from_h`: `from_h` re-admits every entry under the compile's rules and
  recomputes every digest, so a corrupted file is refused; the 0700 runtime directory is the trust.
- `McpSourceBuilder#build` handles each server on its own: compile live; on success write
  `<runtime>/mcp-catalogs/<server>.json` (0600, keyed by the server's configuration digest). A server
  that did not answer (network or spawn failure, timeout) is planned from that file; one that answered
  wrongly is not. With neither, the server is skipped and named in `missing`, and probes backed by it
  are dropped. Calls already connect lazily and turn an unreachable server into a tool error.
- `WorkerRuntime`: a source missing a server is rebuilt for the next session at most once a minute; the
  replaced source stays open until shutdown because a turn may still be calling through it.

**S2 — MCP tools in the work loop.** Each admitted MCP tool (not websearch, not probe-backed) is shown
under a tool-name-safe alias `mcp_<server>_<tool>` (a collision is warned and the later tool hidden),
with its pinned input schema and an attributed description; the gate maps the alias back to `mcp:<server>/<tool>` the way `WorkWeb` maps web tools.
Approval: `base.yaml` classifies `mcp:*` as `local_execute`, so an operator-declared read-only MCP tool
lands in tier `read` (ADR-053 §7) and every other MCP tool still asks.

**S3 — web in ordinary turns.** The adapter gains `read_url`: any public https page, every egress check
kept. The host is the provenance gate: an ordinary turn sees `web_search` and `read_url`, and `read_url`
runs only for a URL extracted from a message the user wrote in the conversation, or from the `results` of a
succeeded `web_search` in this turn, compared whole (scheme and trailing slash ignored).
`mcp:websearch/read_url` never appears on a planning surface (legacy planner, research children);
`read_page` stays search-only for both.

**S4 — operator config.** `sources.websearch` (Brave search, direct reader, egress declaration, grant)
with `read_only_tools: [search, read_page, read_url]`, the Brave key from the repo `.env` passed to the
worker's environment, `read_only_tools` for ALMS unchanged.

## Future (deferred, not built)

- Refreshing a cached catalog while the server is down, or on a schedule.
- Following links found in a page that was read (needs link extraction in `PageText`).
- PDF and JavaScript-rendered pages.
- Showing the ALMS write tools in chat: they ask for approval, and the Telegram channel's
  `approvals.mode: deny_only` refuses every ask.
