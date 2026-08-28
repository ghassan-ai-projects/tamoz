# ADR-054 — Websearch is the fourth capability source, realized as a reserved MCP server with governed egress

**Status:** Accepted 2026-08-26
**Date:** 2026-08-29 (recording a shipped decision)
**Relates to:** ADR-030 (one local capability catalog — **this ADR extends it from three named sources to four**), ADR-029 (MCP native at the edge), ADR-014 (no plugin API; the source set is closed), ADR-046/ADR-047 (egress and content governance).

The capability catalog's closed source set is **four** named sources — local tools, skills,
MCP, and **websearch** — not the three ADR-030 records. Websearch is not a new mechanism: it
is a reserved MCP server id with a governed egress policy, which is exactly why it can be a
first-class source without widening the capability surface.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

ADR-030 established one local capability catalog governing "local tools, MCP, and skills" —
three sources, a closed set (ADR-014: adding a source is a release, not a plugin). Since
then, websearch (P17) shipped as a first-class capability the operator can enable, and
product.md now describes the registry as "a closed set of **four** built-in sources — local
tools, skills, MCP servers, websearch." ADR-030 was never updated; the record undercounts the
sources the code exposes.

The design question websearch raised: is web access a *new* capability mechanism (a fourth
kind of thing the catalog must understand), or can it reuse an existing one? A new mechanism
would widen the trust surface the catalog reasons about. But web egress also needs governance
that ordinary local tools do not — an allow/deny egress boundary, content limits.

## 2. Decision

**Websearch is the fourth named source in the closed capability set, realized as a reserved
MCP server whose id is `websearch`, carrying its own governed egress policy.**

- Mechanically, websearch is an MCP server (ADR-029), not a new source mechanism.
  `sources.websearch` in configuration is sugar for "an MCP server called `websearch`"; the
  id `websearch` is **reserved** and cannot be claimed by an ordinary MCP server
  (`WEBSEARCH_SERVER_ID = "websearch"`; a user MCP server using that id is refused —
  *"`websearch` is reserved; configure it under `sources.websearch`"*).
- It is nonetheless a **first-class named source** in the closed four-source set the operator
  reasons about — enabled/disabled explicitly, governed by the application's trust
  assignment, and sealed at session construction like every other source.
- Its network reach is bounded by a dedicated **egress policy** in `tamoz-mcp-websearch`
  (`egress_policy`, `egress_client`), the precedent later observability export egress rules
  reuse.

## 3. Consequences

- The catalog's mechanism count stays at what ADR-029/ADR-030 established (MCP + local tools +
  skills); websearch adds a *governed instance*, not a new mechanism to secure.
- Web access is opt-in, application-trusted, and egress-bounded — it cannot become an
  unbounded network primitive the model reaches for freely.
- ADR-030's "three sources" is now stale and must read "four"; this ADR is that revision.
- Reserving the `websearch` id means an operator cannot accidentally (or maliciously) shadow
  the governed websearch with an ordinary MCP server of the same name.
- Cost: one reserved id and a dedicated egress-policy surface to maintain. Cheap relative to a
  new source mechanism.

## 4. Invariant linkage

- **ADR-030 intersection rule** — effective access is the intersection of application, agent,
  accepted-plan, parent/schedule, and source limits; websearch is subject to it like any
  source.
- **ADR-014 / closed set** — adding or changing a source is a release of the owning gem, not a
  plugin; the four-source set is closed.
- **ADR-046/047** — the egress policy governs what leaves the process; websearch egress is the
  precedent for exporter egress.

## 5. Threat model

**Asset:** the agent's ability to reach the network and to exfiltrate context through a query.

| Threat | Vector | Mitigation |
|---|---|---|
| An ordinary MCP server impersonates websearch | Register a server with id `websearch` | The id is reserved; such a server is refused at build time |
| Unbounded network reach | Model treats websearch as a free network tool | Dedicated egress policy bounds destinations and content; source is application-trusted, opt-in |
| Context exfiltration via query text | Sensitive context placed in a search query | Governed under the same content/egress rules; websearch is a named, auditable source, not an ambient capability |

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| Websearch as a brand-new source mechanism | Widens the trust surface the catalog must reason about; reusing MCP keeps the mechanism count fixed |
| An ordinary MCP server named "websearch" with no reservation | An operator's server could shadow the governed one; the reserved id prevents silent substitution |
| A raw HTTP tool exposed to the model | No egress boundary, no application trust assignment; violates ADR-030's "the application assigns authority" |
| Leave ADR-030 saying "three sources" | The record would keep undercounting the shipped capability surface (A4 reality-consistency failure) |

## 7. Verification

Verified against code: 2026-08-29 — `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch.rb`
(module `Tamoz::Mcp::Websearch`, with `egress_policy`/`egress_client`);
`gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` reserves
`WEBSEARCH_SERVER_ID = "websearch"` and documents "one of the four closed-world sources."
product.md already states the four-source set.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`../design/mcp.md`](../design/mcp.md) — the MCP host/source design
- [`../overview/product.md`](../overview/product.md) — the four-source capability registry
