# ADR-014 — No plugin API in v0.1

**Status:** Accepted. *(Tier F — bounds the extension surface.)*

## Decision

Skills and MCP cover the extension need. A plugin API is a compatibility commitment made
before the core stops moving. The capability registry is instead a **closed set** of built-in
sources (ADR-030, ADR-054); adding one is a gem release, not a plugin.

## Verification

Verified against code: 2026-08-29 — product.md documents the closed four-source registry; no plugin entry point exists.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
