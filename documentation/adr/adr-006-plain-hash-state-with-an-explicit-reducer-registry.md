# ADR-006 — Plain Hash state with an explicit reducer registry

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Graph state is a plain `Hash`; how concurrent writes merge is a named, visible reducer per key.

## Context

State needs a record type and a merge rule for writes from parallel nodes. The reference
frameworks use typed annotations and metaprogramming; Ruby already has `Hash` and pattern matching.
The merge rule is where silent data loss happens, so it must be visible.

## Decision

State is a `Hash`. A key that several nodes may write declares a reducer
(`state :message_events, reduce: Tamoz::Reducers.message_events`). Two writes to a key with no
reducer in one superstep fail before commit, naming every writing task. Behavior is configured by
keyword arguments, never by a config hash dispatched on string keys.

## Consequences

State is inspectable and pattern-matchable with no framework types, and every merge rule is a
lambda you can read. **Cost:** no static shape checking; a wrong partial update is caught by its
reducer or a test, not by a type.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| `Data`/`Struct`-typed state | Partial updates against a fixed shape are awkward and every node would construct one |
| Last-writer-wins for unreduced keys *(retrospective, 2026-10-01)* | Silently drops a parallel write; the order would decide the result |
| A `Memory` object family that hides state *(retrospective, 2026-10-01)* | State must be explicit and injected; hidden state defeats replay |
| Config-dict dispatch (`config["configurable"]["llm"]`) *(retrospective, 2026-10-01)* | Stringly typed action at a distance |

## Reopen when

A real graph needs a merge rule that a per-key reducer cannot express (for example, a constraint
across two keys).

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Reducers are explicit and pure | `gems/tamoz-graph/lib/tamoz/reducers.rb` | `test/graph_reducer_test.rb` — `test_reducers_do_not_mutate_inputs` | — |
| Conflicting unreduced writes fail before commit | graph executor | `test/graph_execution_test.rb` — `test_conflicting_last_value_writes_fail_before_state_commit` | — |
