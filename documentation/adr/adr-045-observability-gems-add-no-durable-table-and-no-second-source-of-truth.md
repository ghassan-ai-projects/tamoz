# ADR-045 — The observability gems add no durable table and no second source of truth

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-047](./adr-047-telemetry-is-never-sampled-at-record-time-and-safety-bearing-signals-have-a-reserved-lane.md) (what the journal may lose), [ADR-050](./adr-050-automated-response-durable-evidence.md) (alerting, proposed)

The runtime's durable record is the only history. The observability journal is a bounded, rotating,
lossy local log; anything safety-bearing is reconstructed from the durable record, not read from
telemetry.

## Context

A durable telemetry table would be a second writer contending with the fenced writer (ADR-017) and a
second account of what happened, which drifts. Telemetry also has to be allowed to fail without
affecting execution.

## Decision

- The observability gems create no table in the runtime database.
- The journal is a bounded local file set: it rotates, keeps a fixed number of files, and may drop
  input (counted) when saturated or disabled.
- Safety-bearing counters and traces are derived from the durable record, with trace identity a pure
  function of thread and execution identity (invariant 61).
- Model-usage capture is a separately authorized persistence change that observability reads, not
  owns. Operator-authority records proposed for alerting (silences, rule revisions) are not
  telemetry and are out of scope (ADR-050).

## Consequences

Telemetry can be lost without losing truth. **Cost:** some views are reconstructed rather than
stored, and the journal is not an audit log.
