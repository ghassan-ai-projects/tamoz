# ADR-011 — SQLite is Tamoz Agent's default persistence

**Status:** Accepted.

## Decision

Single file, no server, WAL, one operator. WAL permits one writer, so transactions stay short
and busy retries are bounded. The adapter owns leases, fencing, connection lifecycle,
backup/restore, and file-descriptor tests.

## Verification

Verified against code: 2026-08-29 — `tamoz-sqlite` present; `Tamoz::SQLite::Adapter` high-fan-in.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
