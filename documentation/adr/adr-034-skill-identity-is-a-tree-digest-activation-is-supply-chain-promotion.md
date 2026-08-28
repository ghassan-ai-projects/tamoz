# ADR-034 — Skill identity is a tree digest; activation is supply-chain promotion

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Path or self-claimed version as identity lets a mutable directory silently shadow or swap a skill on resume, making behavior unreproducible and enabling same-version supply-chain swaps.

## Decision

Executable identity is source-qualified name plus canonical tree digest, not a path or
self-claimed version. Same-name cross-source collisions require explicit binding. Install/update
stage in quarantine, validate paths/archives/provenance/capability changes, run comparative
evaluation, and activate atomically as a new catalog/cache epoch. Generated skills are
candidates and cannot evaluate or approve themselves.

## Consequences

Identity is a canonical tree digest; install/update stage in quarantine and activate atomically as a new catalog epoch, and generated skills cannot self-approve. **Cost:** activation is a supply-chain promotion, not a file copy.

## Rejected alternatives

- watching mutable skill directories and loading newest bytes on resume — makes behavior unreproducible and enables silent shadowing and same-version supply-chain swaps.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
