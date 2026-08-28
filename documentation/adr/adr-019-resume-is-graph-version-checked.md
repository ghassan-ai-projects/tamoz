# ADR-019 — Resume is graph-version checked

**Status:** Accepted. *(Tier F.)*

## Decision

Checkpoint format version, graph name/version, and definition digest are persisted; an
incompatible resume fails before user code unless an explicit migration appends a compatible
checkpoint.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
