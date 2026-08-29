# ADR-017 — One fenced writer per thread namespace

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

A concurrent process, or a zombie waking after a pause, could advance history or commit a stale write — corrupting the durable record the whole system trusts.

## Decision

Backends grant renewable leases with monotonic fencing tokens; every pending write and
checkpoint commit validates the fence and base checkpoint. This prevents concurrent history
advancement and zombie commits.

## Consequences

One writer per `(thread, ns)` with monotonic fencing, and every pending write and commit validates the fence and base checkpoint, preventing split-brain history. **Cost:** writes within a namespace are serialized through one owner.

## Verification

Verified against code: 2026-08-29 — Lease and fencing machinery is in `gems/tamoz-sqlite` (`lib/tamoz/sqlite.rb`); the fenced-writer conformance suite exercises it.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
