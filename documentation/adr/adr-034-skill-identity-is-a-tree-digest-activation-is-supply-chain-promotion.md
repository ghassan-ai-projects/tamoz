# ADR-034 — Skill identity is a tree digest; activation is supply-chain promotion

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

Executable identity is source-qualified name plus canonical tree digest, not a path or
self-claimed version. Same-name cross-source collisions require explicit binding. Install/update
stage in quarantine, validate paths/archives/provenance/capability changes, run comparative
evaluation, and activate atomically as a new catalog/cache epoch. Generated skills are
candidates and cannot evaluate or approve themselves.

## Rejected alternatives

- watching mutable skill directories and loading newest bytes on resume — makes behavior unreproducible and enables silent shadowing and same-version supply-chain swaps.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
