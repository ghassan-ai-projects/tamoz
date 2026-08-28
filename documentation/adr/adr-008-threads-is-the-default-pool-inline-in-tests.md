# ADR-008 — `:threads` is the default pool; `:inline` in tests

**Status:** Accepted.

## Decision

Agent work is network-bound, so the GVL releases during the waits that matter. `:inline` is the
deterministic debug/test default; `:fibers` requires `async`, lazily. All three are
observationally equivalent by conformance test — which is why the default can change later.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Pool::Threads` is present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
