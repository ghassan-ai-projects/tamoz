# ADR-005 — Interrupt by `throw`, not by exception

**Status:** Accepted.

## Decision

In Ruby, `throw` cannot be caught by `rescue`, so LangGraph's most-violated rule ("never wrap
`interrupt()` in a bare `try/except`") becomes structurally impossible. The matching `catch`
wraps the node inside each worker; a coordinator catch cannot receive a throw from another
thread.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
