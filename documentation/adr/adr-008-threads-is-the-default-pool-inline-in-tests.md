# ADR-008 — `:threads` is the default pool; `:inline` in tests

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Graph tasks use a thread pool by default. Inline mode runs them one at a time for tests and
debugging; both modes use the same synchronous API.

## Context

Agent tasks often wait for model or tool responses. Threads let independent tasks overlap those
waits. Running tasks one at a time makes their execution order easier to inspect, without needing
a separate async/await API.

## Decision

`Tamoz::Configuration` supports `:threads` (the default) and `:inline`. Inline tasks run on the
calling thread; threaded tasks run in the worker pool. Both return through the same synchronous API.

For successful executions with deterministic graph behavior and matching graph definitions, inputs
and execution identities, both modes preserve the same ordered checkpoint state history. This does not guarantee identical
task timing or make behavior that depends on shared mutable data or external timing deterministic.

`:fibers` is rejected with a configuration error. A fiber pool may be added only after it passes
the same pool conformance tests; there is no separate async/await API.

## Consequences

Threads suit work that waits on I/O; inline mode simplifies scheduling during tests and debugging.
Inline execution does not make model responses or arbitrary application code deterministic.

**Cost:** threads do not generally speed up CPU-bound Ruby code under MRI's global lock, and a
fiber pool is unavailable. Tests must exercise threaded execution when concurrency matters.
