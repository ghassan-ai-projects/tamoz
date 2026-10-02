# ADR-007 — Frozen state is handed to nodes

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Nodes read a snapshot of state that they cannot change in place. They return updates for the
graph to apply.

## Context

Several nodes can read the same state at the same time. If one changes that state directly,
another may see different input depending on which node runs first. A saved copy of state must
also be protected from later changes.

## Decision

Tamoz prepares state through `Tamoz::StateCodec`, which encodes values and reconstructs them.
For built-in hashes, arrays and strings, this produces copies that are frozen, including nested
values. Freezing only the outer hash would leave its contents open to changes.

Nodes return updates rather than changing their input. For example, a node increments a declared
`count` key by returning a new hash:

```ruby
{count: state[:count] + 1}
```

Assigning directly to `state[:count]` raises `FrozenError`. The graph applies returned updates
using the merge rules in ADR-006.

Unsupported values and cycles are rejected. Custom Ruby objects need a registered encoder,
decoder and immutability check; Tamoz accepts them only when that check passes.

## Consequences

Nodes cannot accidentally change the built-in state values shared with other nodes. This also
protects saved snapshots, but does not by itself guarantee that running the graph again produces
the same result.

**Cost:** nodes must create updates instead of changing state in place. Custom types require
serialization support and a trustworthy immutability check.
