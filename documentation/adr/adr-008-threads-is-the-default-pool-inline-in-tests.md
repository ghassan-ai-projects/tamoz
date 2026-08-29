# ADR-008 — `:threads` is the default pool; `:inline` in tests

**Status:** Accepted.
**Tier:** C (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Agent work is dominated by network I/O (model and tool calls), where the GVL is released; tests and debugging need determinism instead.

## Decision

Agent work is network-bound, so the GVL releases during the waits that matter. `:inline` is the
deterministic debug/test default; `:fibers` requires `async`, lazily. All three are
observationally equivalent by conformance test — which is why the default can change later.

## Consequences

Good default concurrency without threads fighting the GVL on CPU-bound work, deterministic `:inline` for tests, and optional `:fibers`. Because the three pools are conformance-equivalent, **the default can be changed later without behavioral risk** — the reason this choice is low-stakes.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Pool::Threads` is present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
