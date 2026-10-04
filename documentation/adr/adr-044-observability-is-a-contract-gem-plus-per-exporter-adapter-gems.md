# ADR-044 — Observability is a contract gem plus per-exporter adapter gems

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (why exporters are a closed set), [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md), [ADR-060](./adr-060-tamoz-diagnoses-itself-read-only-from-its-durable-record.md) (the read-only diagnosis the gem also owns)

`tamoz-observability` owns the signal catalog, recorder, journal, and exporter seam. Each exporter
(`tamoz-otel` today) is its own gem that passes the contract and owns its egress policy.

## Context

The exporter is the one seam that carries telemetry out of the process. As a plugin point it would be
an unversioned egress path with no conformance gate.

## Decision

- The contract gem owns a closed, versioned signal catalog (a changed attribute set needs a version
  bump), the recorder (which does not raise into its caller over a malformed payload), the bounded journal, and the
  exporter-adapter seam.
- The contract gem also owns the read-only reconstruction contract, `TelemetryReader`, which a
  durable store implements without referencing this gem, and the pure diagnosis built on it
  (ADR-060).
- Each exporter is a separate gem depending on the contract gem, with its own egress policy:
  trusted destinations only, local endpoints by explicit opt-in, credentials as references, no
  redirects or proxy environment.

## Consequences

Telemetry egress is reviewed code with tested destination rules. **Cost:** each exporter is a Tamoz
release (ADR-014).

## History

- 2026-10-04 — Added the reconstruction contract and read-only diagnosis to what the contract gem
  owns (ADR-060); owner-requested self-diagnosis work.
