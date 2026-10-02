# ADR-004 — Explicit `Tamoz.seq`; no native `Proc#>>` (RETIRED)

**Status:** Retired 2026-10-01 — withdrawn
**Date:** 2026-07-30

This decision is no longer in force. It named `Tamoz.seq` / `Tamoz.step` the canonical way to
compose `(state, context)` callables, because `Proc#>>` drops `context`, and deferred a
`tamoz-chain` gem. Neither API was ever built: composition is the graph (`Tamoz.graph`) plus
ordinary Ruby, and no consumer has needed more. Nothing replaces it; a future composition API
would be a new ADR.

- **Why it was withdrawn:** [`RETIRED.md`](../RETIRED.md).
