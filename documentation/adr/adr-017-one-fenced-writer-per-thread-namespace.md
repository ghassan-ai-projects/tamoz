# ADR-017 — One fenced writer per thread namespace

**Status:** Accepted. *(Tier F.)*

## Decision

Backends grant renewable leases with monotonic fencing tokens; every pending write and
checkpoint commit validates the fence and base checkpoint. This prevents concurrent history
advancement and zombie commits.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
