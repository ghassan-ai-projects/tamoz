# ADR-030 — One local capability catalog governs all sources

**Status:** Accepted 2026-07-30; **extended by [ADR-054](./adr-054-websearch-capability-source.md).**
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-054 (see the [catalog](./README.md))

## Decision

Capabilities use source-qualified content-addressed descriptors. **The application** — not a
remote server, skill, memory, or model — assigns trust, effect class, scope, and authority.
Effective access is the intersection of current application, agent, accepted-plan,
parent/schedule, and source limits. Epoch changes occur only at explicit turn boundaries. The
closed source set is now **four**: local tools, skills, MCP, and websearch (ADR-054).

## Rejected alternatives

- importing MCP annotations or skill `allowed-tools` as permissions — content from a different trust boundary can only request or narrow authority.

## Verification

Verified against code: 2026-08-29 — `tamoz-agent-capabilities` present; four sources wired (audit finding #4).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
