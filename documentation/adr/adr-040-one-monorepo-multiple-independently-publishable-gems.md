# ADR-040 — One monorepo, multiple independently publishable gems

**Status:** Accepted 2026-07-30; **instantiated by [ADR-052](./adr-052-agent-gem-decomposition.md).**
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-052 (see the [catalog](./README.md))

## Decision

One repository for framework gems, Tamoz Agent, conformance fixtures, examples, and release
tooling. Each gem has an explicit manifest and dependency boundary and can be packaged
independently. Before 1.0, releases coordinate through one compatibility matrix but versions
change only for affected gems. **Repository proximity grants no runtime dependency.**

## Rejected alternatives

- separate repositories from the first commit — multiplies cross-repo changes, CI, fixtures, and release coordination before ownership diverged.

## Verification

Verified against code: 2026-08-29 — 27 gems, per-gem gemspecs. *(Audit O1: the `agentic-stream` Go authority is a second repo whose relationship to this rule needs an ADR.)*

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
