# ADR-054 — Websearch is the fourth capability source, realized as a reserved MCP server with governed egress

**Status:** Accepted 2026-08-26
**Date:** 2026-08-26
**Tier:** F
**Implementation:** Complete
**Amends:** [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (adds the fourth source)
**Relates to:** [ADR-029](./adr-029-mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk.md) (the mechanism it reuses), [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (the closed source set)

Web access is a named, operator-enabled capability source, built as an MCP server under the reserved
id `websearch` with its own egress policy. It adds no new mechanism to secure; it adds a governed
instance of one.

## Context

Web search shipped as a first-class capability. It could have been a new kind of source — widening
what the catalog must reason about — or reuse MCP. But web egress needs governance plain MCP servers
do not get: destination rules, budgets, and protection against an operator's own server
impersonating it.

## Decision

- `sources.websearch` in configuration declares an MCP server with id `websearch`. The id is
  reserved: an ordinary MCP server using it is refused at build time.
- Its egress policy (`tamoz-mcp-websearch`) bounds destinations and budgets; the declaration is
  pinned in the session record, and resuming with a changed egress declaration stops.
- Its tools are tier `network` in approval policy (asked by default); an operator may declare them
  read-only for research sub-agents that cannot ask.
- Like every source, it is sealed at session construction and grants nothing by itself (ADR-030).

## Consequences

Web access is opt-in, operator-trusted, and egress-bounded, with one mechanism count. **Cost:** a
reserved id and an egress surface to maintain.

## Invariants

- 35 — capability authority is local and intersected.
- 37 — MCP calls preserve Tamoz authorization, durability, and uncertainty.

## Threat model

**Asset:** network reach and the context that could leave through it. **Adversary:** injected
content steering the agent, or a server impersonating websearch.

| Threat | Mitigation |
|---|---|
| An ordinary MCP server shadows websearch | Reserved id refused at build |
| Unbounded network reach | Egress policy bounds destinations and budgets; tier `network` asks by default |
| Egress rules change under a running session | Declaration pinned; changed egress on resume stops |
| Context exfiltration in query text | **Not mitigated by content rules:** query text reaches the search provider as written |

**Residual risk:** whatever the model puts in a query reaches the provider, and when the operator
declares websearch read-only, nobody is asked first.
