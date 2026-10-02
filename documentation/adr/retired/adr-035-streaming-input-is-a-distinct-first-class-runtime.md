# ADR-035 — Streaming input is a distinct first-class runtime (RETIRED)

**Status:** Retired 2026-10-01 — superseded by [ADR-036](../adr-036-cognition-sees-only-a-sealed-situation-snapshot-never-raw-evidence.md) and [ADR-055](../adr-055-two-repo-authority-split.md)
**Date:** 2026-07-30

This decision is no longer in force as its own record. It said unbounded evidence never enters a
graph or a model directly, and that a Ruby `tamoz-stream` runtime owned channel admission, temporal
state, Situations, and replay. The continuous plane moved to the Go `agentic-stream` runtime
(ADR-055) and `tamoz-stream` became the episode worker. The surviving rule — evidence becomes a
sealed Situation before any cognition — is now stated by ADR-036.

- **Why it was retired:** [`RETIRED.md`](../RETIRED.md).
