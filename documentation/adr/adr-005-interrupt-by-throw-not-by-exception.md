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

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An `Interrupt` exception (LangGraph's design) *(retrospective, 2026-10-01)* | Any broad `rescue` in a node swallows it; the framework cannot detect that |
| A sentinel return value *(retrospective, 2026-10-01)* | A node can return the sentinel by accident, and nested helpers must propagate it by hand |

## Reopen when

A pool is added whose tasks do not run on a Ruby stack the pool controls (for example, out of
process), so a worker-local `catch` is impossible.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The throw is caught inside each worker | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool::Base#execute`) | `test/core_pool_test.rb` — `test_interrupt_is_captured_inside_each_worker` | — |
| A normal value is never read as an interrupt | same | `test/core_pool_test.rb` — `test_normal_value_cannot_be_confused_with_an_interrupt` | — |
| The cursor uses `throw` | `gems/tamoz-graph/lib/tamoz/graph/interrupt.rb` | `test/graph_identity_test.rb` — `test_interrupt_cursor_is_explicit_positional_and_uses_throw` | — |
