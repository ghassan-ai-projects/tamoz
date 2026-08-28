# ADR-044 — Observability is a contract gem plus per-exporter adapter gems

**Status:** Accepted 2026-08-10. *(Tier F.)*
**Date:** 2026-08-10

## Decision

The contract gem owns the signal catalog, recorder, journal, and exporter-adapter seam; each
exporter is a separate adapter gem passing the contract gem's conformance suite. The exporter
list is a closed set; adding one is a contract-gem release, not a plugin (ADR-014 stands).

## Rejected alternatives

- an exporter plugin API — an unversioned extension point with no conformance gate on the one surface that carries telemetry out of the process.

## Verification

Verified against code: 2026-08-29 — `tamoz-observability` and `tamoz-otel` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
