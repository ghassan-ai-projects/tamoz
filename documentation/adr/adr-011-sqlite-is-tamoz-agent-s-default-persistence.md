# ADR-011 — SQLite is Tamoz Agent's default persistence

**Status:** Accepted.

## Context

A single-operator durable agent needs persistence without running a server, and its workload is essentially one writer with short transactions.

## Decision

Single file, no server, WAL, one operator. WAL permits one writer, so transactions stay short
and busy retries are bounded. The adapter owns leases, fencing, connection lifecycle,
backup/restore, and file-descriptor tests.

## Consequences

Zero-ops single-file durability with WAL, and the adapter owns leases, fencing, backup/restore, and file-descriptor behavior. **Cost:** WAL permits only one writer, so transactions must stay short and busy-retries bounded — this is not a multi-writer store.

## Verification

Verified against code: 2026-08-29 — `tamoz-sqlite` present; `Tamoz::SQLite::Adapter` high-fan-in.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
