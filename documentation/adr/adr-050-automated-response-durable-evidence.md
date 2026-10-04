# ADR-050 — Automated responses act only on durable evidence, under the subsystem that owns the effect

**Status:** Proposed
**Date:** 2026-08-10
**Tier:** F
**Implementation:** Not built — ratified when observability phase 5 (alerting) ships with fault-injection proof of the non-degraded-window precondition
**Relates to:** [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md), [ADR-047](./adr-047-telemetry-is-never-sampled-at-record-time-and-safety-bearing-signals-have-a-reserved-lane.md), [ADR-022](./adr-022-reviewed-plan-gate.md), [ADR-028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md), [ADR-060](./adr-060-tamoz-diagnoses-itself-read-only-from-its-durable-record.md) (diagnosis computes conditions and has no actuator)

Observability may compute that a condition holds; it may never act on it. A response fires only on
durable evidence over a window with no counted telemetry loss, and runs in the subsystem that already
governs that effect, under that subsystem's gates.

## Context

Phases 1–4 of observability only observe. Phase 5 adds alerting, and with it the temptation every
telemetry stack meets: let the thing that notices a problem also fix it (auto-restart, auto-approve,
run a hook). That would be an authority path outside reviewed plans (ADR-022) and bounded
remediation (ADR-028).

## Decision

- Observability ships conditions: it records that a threshold was crossed. It ships no actuator, no
  general command hook, no auto-restart, and no auto-approval.
- A response requires durable evidence (not an in-memory sample) over a window with no counted loss
  (ADR-047); a degraded window blocks the response.
- The response runs in the owning subsystem under its gates — a healing rule under ADR-028, any
  action under a reviewed plan per ADR-022.
- Operator-authority records (silences, rule revisions) are not telemetry and have their own
  governance.

This proposes invariant clause 62; the invariant contract still ends at 61 until this is ratified.

Any specific automated effect needs a new ADR naming the effect, routing it through ADR-022
or ADR-028, and proving the non-degraded-window precondition with a fault-injection test.

## Consequences

Alerting cannot become a control plane. **Cost:** "when X, run Y" cannot be wired inside
observability; it must be a governed rule in the owning subsystem.

## Invariants

- Proposed 62 — automated response only on durable evidence over a non-degraded window, executed by
  the owning subsystem.
- 61 — safety-bearing observability is derived from durable evidence.

## Threat model

**Asset:** the ability to cause an effect from a measurement. **Adversary:** a noisy or spoofed
metric, or lost telemetry read as health.

| Threat | Mitigation |
|---|---|
| A noisy metric auto-approves or restarts | No actuator in observability |
| Action on lost or partial telemetry | Degraded window blocks the response |
| A component vouches for its own health | Conditions come from the durable record |

**Residual risk:** a correctly computed condition can still trigger a rule whose own gate is weak;
that is the owning subsystem's risk.
