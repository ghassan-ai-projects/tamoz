# ADR-007 — Frozen state is handed to nodes

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Durable values are normalized, copied, and recursively frozen at commit; a value that cannot be
made immutable is refused before execution.

## Context

Nodes in one superstep read the same snapshot concurrently, and that snapshot is checkpointed. A
mutable value handed to a node can be mutated by a sibling, changed after commit, or fail to
round-trip — each a nondeterministic replay.

## Decision

The state codec normalizes durable values to codec-registered immutable types and freezes them
recursively (`Tamoz::Core.deep_freeze`). Hashes, arrays, and strings are copied and frozen;
cyclic, ambiguous, or unregistered mutable objects fail closed. Shallow freeze is not enough.

## Consequences

Sibling nodes cannot mutate shared state, and a checkpoint is the same bytes on replay. **Cost:**
nodes return new values instead of mutating; custom value types must register an immutable codec.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Shallow freeze | Nested arrays and hashes stay mutable |
| Copy-on-read without freezing *(retrospective, 2026-10-01)* | Costs a copy per read and still lets a node mutate its copy and leak it into a write by accident |

## Reopen when

Copy-and-freeze cost shows up as a measured bottleneck in a real workload.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Round-trips are deterministic and immutable | `gems/tamoz-core/lib/tamoz/core.rb` (`deep_freeze`), state codec | `test/core_state_codec_test.rb` — `test_built_in_round_trip_is_deterministic_and_immutable` | — |
| Unsupported, cyclic, and ambiguous values fail closed | state codec | `test/core_state_codec_test.rb` — `test_sensitive_unsupported_cyclic_and_ambiguous_values_fail_closed` | — |
| Registered types must declare immutability | state codec | `test/core_state_codec_test.rb` — `test_registration_requires_and_enforces_an_explicit_immutability_contract` | — |
