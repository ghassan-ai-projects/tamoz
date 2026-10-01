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
