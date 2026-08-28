# ADR-004 — Explicit `Tamoz.seq`; no native `Proc#>>`

**Status:** Accepted (revised after an executable counterexample).

## Context

Ruby's native `Proc#>>` is the obvious composition primitive, but Tamoz nodes take a `(state, context)` pair and `>>` forwards only the first result — silently dropping `context`.

## Decision

Native `Proc#>>` passes only the first proc's result and loses Tamoz's required `context`
argument. `Tamoz.seq` is the canonical composition API; `Tamoz.step` adapts two-argument
callables. `tamoz-chain` itself is deferred until a real consumer proves graph + ordinary Ruby
composition is insufficient.

## Consequences

One explicit, correct composition API to learn (`Tamoz.seq` / `Tamoz.step`) instead of a stdlib operator whose semantics don't fit. **Cost:** users must reach for `seq` rather than `>>`; `tamoz-chain` stays unbuilt until a real consumer proves ordinary Ruby composition is insufficient.

## Verification

Verified against code: 2026-08-29 — `tamoz-chain` is absent from the tree (correctly deferred).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
