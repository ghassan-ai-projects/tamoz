# ADR-008 — `:threads` is the default pool; `:inline` in tests

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Graph tasks run on a thread pool by default and inline when determinism matters; there is one
synchronous API and no fiber pool until one passes the same conformance tests.

## Context

Agent work waits on model and tool calls, where Ruby releases the GVL, so threads give real
parallelism. Tests and debugging need a deterministic order instead. An async/await API beside the
sync one would double the surface.

## Decision

`Tamoz::Configuration` accepts exactly `:threads` (the default) and `:inline`. Both commit
byte-identical histories for the same graph. `:fibers` is refused with a configuration error until
a fiber pool passes the pool conformance tests. There is no async API.

## Consequences

Good default concurrency for I/O-bound work and a deterministic mode for tests. Because inline and
threads commit identical bytes, switching between them is safe. **Cost:** CPU-bound nodes get no
parallelism under the GVL, and fiber-based I/O is unavailable.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An async/await API beside the sync one *(retrospective, 2026-10-01)* | Two APIs to document and keep equivalent |
| Fibers (`async` gem) as default *(retrospective, 2026-10-01)* | Adds a dependency and a scheduler for no measured gain over threads on I/O waits |

## Reopen when

A measured workload is bound by thread count or memory per thread, or a fiber pool passes the pool
conformance tests.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only `:inline` and `:threads` are accepted; threads is default | `gems/tamoz-core/lib/tamoz/configuration.rb` (`CONCURRENCY_MODES`, defaults) | source inspection | No test asserts the default or the accepted set |
| `:fibers` is refused | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool.for`) | `test/core_pool_test.rb` (asserts `ConfigurationError` for `:fibers`) | — |
| Inline and threads commit identical histories | graph executor | `test/graph_execution_test.rb` — `test_inline_and_threads_commit_byte_identical_histories` | One graph shape, not a property over all graphs |
