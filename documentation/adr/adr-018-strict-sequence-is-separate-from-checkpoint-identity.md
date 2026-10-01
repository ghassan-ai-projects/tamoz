# ADR-018 — Strict sequence is separate from checkpoint identity

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Checkpoints are ordered by a backend-assigned integer sequence per `(thread, ns)`; their opaque ids
(UUIDv7, ULID) are never used for order.

## Context

Time-ordered ids are convenient, but their order depends on clocks, and clocks skew and jump. Under
concurrency, two ids minted on different hosts or after a clock step can sort the wrong way.

## Decision

The store assigns each appended checkpoint a strictly increasing integer within its `(thread, ns)`
(gaps allowed). All ordering, "latest", and base checks use that sequence. Correctness never
depends on wall-clock time or lexical id order.

## Consequences

History order is exactly append order. **Cost:** the backend must assign and store the sequence.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| UUIDv7/ULID lexical order as the sequence | Not safe under clock skew or across hosts |
| Timestamps *(retrospective, 2026-10-01)* | Same problem, plus collisions at clock resolution |

## Reopen when

Never expected; only if a backend cannot assign a per-namespace sequence atomically.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Strict sequence; stale base refused | checkpointers (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_appender.rb`) | `test/graph_identity_test.rb` — `test_memory_checkpointer_assigns_strict_sequence_and_rejects_stale_base` | The in-memory checkpointer is tested here; SQLite through `test/sqlite_checkpoint_test.rb` |
| A fork appends a new sequence | same | `test/graph_identity_test.rb` — `test_fork_uses_historical_parent_but_appends_new_sequence` | — |
