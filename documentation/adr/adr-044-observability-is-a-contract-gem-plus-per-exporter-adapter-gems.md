# ADR-044 — Observability is a contract gem plus per-exporter adapter gems

**Status:** Accepted 2026-08-10.
**Date:** 2026-08-10
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

An exporter plugin API would turn the one seam that carries telemetry out of the process into an unversioned extension point with no conformance gate.

## Decision

The contract gem owns the signal catalog, recorder, journal, and exporter-adapter seam; each
exporter is a separate adapter gem passing the contract gem's conformance suite. The exporter
list is a closed set; adding one is a contract-gem release, not a plugin (ADR-014 stands).

## Consequences

A contract gem owns the signal catalog, recorder, journal, and exporter seam, and each exporter is a separate adapter gem passing the conformance suite; the exporter set is closed. **Cost:** adding an exporter is a contract-gem release.

## Rejected alternatives

- an exporter plugin API — an unversioned extension point with no conformance gate on the one surface that carries telemetry out of the process.

## Verification

Verified against code: 2026-08-29 — `tamoz-observability` and `tamoz-otel` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
