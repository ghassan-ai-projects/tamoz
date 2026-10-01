# ADR-005 — Interrupt by `throw`, not by exception

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

A node pauses with `throw :tamoz_interrupt`, caught inside the worker that ran it, so no
`rescue` in user code can swallow a pause.

## Context

LangGraph's interrupt is an exception, and its most repeated warning is "never wrap `interrupt()`
in a bare `try/except`" — a rule the framework cannot enforce. A swallowed interrupt is worse than a
crash: an approval gate that never pauses. Ruby's `throw`/`catch` is not an exception and `rescue`
cannot intercept it.

## Decision

`InterruptCursor#call` throws `:tamoz_interrupt`. The matching `catch` wraps each task inside the
pool worker that executes it (`Tamoz::Pool::Base#execute`) and returns a typed `Interrupted`
result; nothing above the worker catches it. A throw never crosses a thread.

## Consequences

User code can `rescue StandardError` freely without breaking pauses. **Cost:** every pool
implementation must install the `catch` around each task, and an interrupt is scoped to one
worker's task — there is no cross-thread pause.
