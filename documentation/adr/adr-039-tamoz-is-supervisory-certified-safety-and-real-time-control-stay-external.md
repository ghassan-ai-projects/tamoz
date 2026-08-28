# ADR-039 — Tamoz is supervisory; certified safety and real-time control stay external

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Marketing a general agent framework as a safety or motion controller is unsafe: Tamoz has neither hard real-time semantics nor domain certification, and an LLM cannot be the final safety barrier.

## Decision

The first physical profile observes, diagnoses, recommends, and may perform explicitly granted
bounded reversible commands through independently safe automation. R4 life/safety-critical
control is advisory-only. Emergency stops, guarding, motion/PLC loops, functional-safety
communication, and interlocks remain external, authoritative, and impossible for
self-healing/self-improvement to weaken.

## Consequences

Tamoz observes, diagnoses, recommends, and may perform explicitly-granted bounded reversible commands through independently-safe automation, while life/safety-critical control stays external and authoritative. **Cost:** the product deliberately stops short of certified or real-time control.

## Rejected alternatives

- marketing a general agent framework as a robot/safety controller — Tamoz has neither hard real-time semantics nor domain certification, and an LLM cannot be the final safety barrier.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
