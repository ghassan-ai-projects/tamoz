# ADR-039 — Tamoz is supervisory; certified safety and real-time control stay external

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

The first physical profile observes, diagnoses, recommends, and may perform explicitly granted
bounded reversible commands through independently safe automation. R4 life/safety-critical
control is advisory-only. Emergency stops, guarding, motion/PLC loops, functional-safety
communication, and interlocks remain external, authoritative, and impossible for
self-healing/self-improvement to weaken.

## Rejected alternatives

- marketing a general agent framework as a robot/safety controller — Tamoz has neither hard real-time semantics nor domain certification, and an LLM cannot be the final safety barrier.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
