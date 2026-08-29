# ADR-029 — MCP is native at the edge and uses the official Ruby SDK

**Status:** Accepted 2026-07-30; **shipped** (`tamoz-mcp`).
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Reimplementing MCP inside Tamoz would couple graph correctness to a fast-moving protocol, while the host's local policy, effect, and consent semantics are genuinely Tamoz's to own.

## Decision

`tamoz-mcp` is an optional first-class host/server package using the official `mcp` gem for
protocol, transports, OAuth, and schemas, while Tamoz owns local policy, effect identity,
durable elicitation, content bounds, supervision, catalog epochs, and evaluation.

## Consequences

The official SDK owns wire compatibility and Tamoz owns policy, effect identity, durable consent, and catalog epochs. **Cost:** a dependency on the SDK's release cadence and explicit protocol-version compatibility windows.

## Rejected alternatives

- implementing JSON-RPC/MCP inside Tamoz — duplicates a fast-moving standard and couples graph correctness to protocol churn.

## Verification

Verified against code: 2026-08-29 — `tamoz-mcp` and `tamoz-mcp-websearch` present (supersedes the "deferred/post-v0.1" timing of the retired ADR-012).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
