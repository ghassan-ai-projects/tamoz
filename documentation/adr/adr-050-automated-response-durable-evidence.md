# ADR-050 — Automated responses act only on durable evidence, under the subsystem that owns the effect

**Status:** Proposed — observability phase 5
**Date:** 2026-08-10 (design); renumbered from a mislabeled "ADR-048" on 2026-08-29
**Relates to:** ADR-044 (observability is contract + adapters), ADR-045 (no durable telemetry table), ADR-047 (sampling never drops safety signals), ADR-022 (nothing acts without a reviewed plan), ADR-028 (self-healing is bounded remediation).

This ADR governs *alerting and automated response* in the observability plane. It exists as
its own number because it was originally written as "ADR-048" in
[`OBSERVABILITY_DESIGN.md` §18.7](../../docs/OBSERVABILITY_DESIGN.md) at the same time the
model-transport decision independently took 048 — a collision this migration resolves by
giving the observability-automation decision the next free number, 050.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

Observability phases 1–4 are strictly *observer-only*: the recorder can never raise into the
caller, and it adds no durable table (ADR-045). Phase 5 introduces alerting — conditions
computed over the record — and with it the temptation every telemetry stack eventually
faces: let the thing that *notices* a problem also *act* on it (auto-restart, auto-approve,
run a hook). That is exactly how a monitoring plane grows an unaudited authority path.

Tamoz's whole safety claim is that authority flows through reviewed plans (ADR-022) and
bounded, verified remediation rules (ADR-028) — never through a side channel. An alerting
engine that could execute would be that side channel.

## 2. Decision

**An automated response is triggered only by durable evidence over a non-degraded window,
and is executed only by the subsystem that already governs the effect — never by
observability itself.**

- Observability *ships conditions*: it computes and records that a threshold was crossed.
- It does **not** ship an actuator. There is no general command hook, no auto-restart, no
  auto-approval, and no condition inside observability that grants authority.
- A response acts on the durable record (not an in-memory sample), requires the window to be
  non-degraded (telemetry loss is visible and blocks action rather than silently arming it),
  and is carried out by the owning subsystem under that subsystem's existing gates
  (self-healing rules under ADR-028; any action under a reviewed plan per ADR-022).

This is [INVARIANTS.md](../../docs/design-v0.1/INVARIANTS.md) **clause 62**.

## 3. Consequences

- Alerting can be added without turning telemetry into a control plane. The observability
  gems keep their "no authority, observer-only" property from phases 1–4.
- Operator-authority records created by phase 5 (silences, rule revisions) are explicitly
  *not telemetry*; they are out of scope for ADR-045's "no durable table" rule (§18.4) and
  live under their own governance.
- A degraded telemetry window fails safe: an automated response cannot fire on evidence the
  system admits it may have lost.
- Cost: an operator cannot wire "when X, run Y" directly in the observability layer; the
  action must be expressed as a governed rule in the owning subsystem. That indirection is
  the point.

## 4. Invariant linkage

- **Clause 62** — automated response triggered only by durable evidence over a non-degraded
  window, executed only by the owning subsystem.
- Depends on **clause 61** (safety-bearing observability derived from durable evidence,
  never self-reported) and **ADR-047** (safety-bearing signals are never sampled away).

## 5. Threat model

**Asset:** the ability to cause an effect (restart, approval, command) from a *measurement*.

| Threat | Vector | Mitigation |
|---|---|---|
| A noisy metric auto-approves or auto-restarts | Threshold-action engine inside observability | No actuator exists in the observability plane; the response runs in the owning subsystem under its gates |
| Action fires on lost/partial telemetry | Degraded window read as healthy | Non-degraded-window precondition; telemetry loss is counted and reported (clause 61) |
| Self-report launders a false condition into action | Component vouches for its own health | Conditions are computed from the durable record, not reported by the component they describe (clause 61) |

## 6. The bar to change it

Making observability able to *execute* anything requires a new ADR that (a) states the exact
effect, (b) routes it through ADR-022's reviewed-plan gate or ADR-028's bounded-rule gate,
and (c) proves the non-degraded-window precondition with a fault-injection test. A general
hook is a permanent non-goal (§23) and cannot be introduced by configuration.

## 7. Rejected alternatives

| Rejected | Why |
|---|---|
| A threshold-action engine inside observability | It is an unaudited authority path; directly contradicts ADR-022 and ADR-028 |
| Auto-restart / auto-approval on an alert | Grants authority from a measurement; the effect must run under the owning subsystem's gate |
| Act on an in-memory alert window | A paused or resumed turn outlives the window; action must rest on the durable record |

## 8. Verification

Verified against code: 2026-08-29 — **not yet implemented (Proposed).** Phase 5 is designed
in `OBSERVABILITY_DESIGN.md` §18 but not shipped; phases 1–4 (observer-only) are in
`gems/tamoz-observability`. This ADR ratifies before implementation; it becomes Accepted +
Verified when phase 5 lands with the clause-62 fault-injection test.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`../design/observability.md`](../design/observability.md) — the observability design summary
- [`../../docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md) — §18 alerting and response
