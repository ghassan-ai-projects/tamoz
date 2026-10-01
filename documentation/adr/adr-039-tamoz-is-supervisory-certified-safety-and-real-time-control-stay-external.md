# ADR-039 — Tamoz is supervisory; certified safety and real-time control stay external

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete — as a boundary; no physical profile has shipped
**Relates to:** [ADR-038](./adr-038-physical-action-is-typed-intent-plus-current-state-policy-never-model-effect.md), [ADR-055](./adr-055-two-repo-authority-split.md)

Tamoz observes, diagnoses, recommends, and may request bounded reversible commands through
independently safe automation. Life- and safety-critical control is advisory only. Emergency stops,
guarding, motion and PLC loops, and interlocks stay external and authoritative.

## Context

Tamoz has no hard real-time semantics and no domain safety certification, and a language model
cannot be the final safety barrier. Marketing a general agent framework as a controller would be
unsafe whatever its tests say.

## Decision

- The first physical profile may observe, diagnose, recommend, and request explicitly granted,
  bounded, reversible commands through automation that is safe on its own.
- R4 (life- and safety-critical) control is advisory only.
- E-stops, guarding, motion and PLC loops, functional-safety communication, and interlocks are
  outside Tamoz, authoritative over it, and cannot be disabled, tuned, or "healed around" by any
  Tamoz component — including self-healing (ADR-028) and self-improvement (ADR-023).
- Replay and shadow workers are given no production effector credentials (a deployment rule; the
  episode worker holds none at all).

Moving Tamoz into safety-critical control requires retiring this product claim and pursuing
certification; changing an ADR alone cannot authorize that transition.

## Consequences

Tamoz can be useful in physical settings without being a safety component. **Cost:** the product
deliberately stops short of certified or real-time control.

## Invariants

- 51 — safety control and replay authority remain outside cognition.

## Threat model

**Asset:** people and equipment. **Adversary:** model error, injection, or a self-modification that
weakens a safeguard.

| Threat | Mitigation |
|---|---|
| Tamoz becomes the last line of defense | External interlocks are authoritative over any Tamoz request |
| Healing or improvement disables a safeguard | Safeguards are outside every Tamoz component's reach |
| A replay or shadow run actuates | No production effector credentials in those workers |

**Residual risk:** if the operator wires Tamoz to equipment without independent interlocks, this
boundary does not exist; it is a deployment requirement, not something code can enforce.
