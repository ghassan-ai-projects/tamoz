# ADR-005 — Interrupt by `throw`, not by exception

**Status:** Accepted.
**Tier:** C (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

LangGraph's interrupt is exception-based, and its most-repeated user warning is *never wrap `interrupt()` in a bare `try/except`* — a rule a framework cannot enforce. Ruby offers `throw`/`catch`, which `rescue` cannot intercept.

## Decision

In Ruby, `throw` cannot be caught by `rescue`, so LangGraph's most-violated rule ("never wrap
`interrupt()` in a bare `try/except`") becomes structurally impossible. The matching `catch`
wraps the node inside each worker; a coordinator catch cannot receive a throw from another
thread.

## Consequences

The most-violated rule of the reference framework becomes structurally impossible in Tamoz. **Cost:** each worker must wrap its node in the matching `catch`, and a throw cannot cross threads, so interrupt is scoped within a worker.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Graph::Executor` (`gems/tamoz-graph/lib/tamoz/graph/executor.rb`) runs the super-step loop that wraps each node in the matching `catch`; interrupt semantics are covered by the invariant conformance suite.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
