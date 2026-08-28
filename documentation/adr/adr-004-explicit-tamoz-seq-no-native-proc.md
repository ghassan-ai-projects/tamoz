# ADR-004 — Explicit `Tamoz.seq`; no native `Proc#>>`

**Status:** Accepted (revised after an executable counterexample).

## Decision

Native `Proc#>>` passes only the first proc's result and loses Tamoz's required `context`
argument. `Tamoz.seq` is the canonical composition API; `Tamoz.step` adapts two-argument
callables. `tamoz-chain` itself is deferred until a real consumer proves graph + ordinary Ruby
composition is insufficient.

## Verification

Verified against code: 2026-08-29 — `tamoz-chain` is absent from the tree (correctly deferred).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
