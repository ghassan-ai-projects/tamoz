# ADR-006 — Plain Hash state with an explicit reducer registry

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Graph state is a plain `Hash`; declared reducers make each key's merge behavior explicit.

## Context

Parallel nodes can update the same state key. Replacing one update with another would silently
lose work. State should be easy to inspect, while the graph must combine updates by an explicit
rule or reject the conflict.

## Decision

State is a `Hash` with keys declared through the graph's `state` API. A key that accepts updates
from several nodes declares a reducer, for example
`state :events, default: [], reduce: Tamoz::Reducers.append`.

A reducer is a named, versioned callable that receives the current value and the writes for that
key. Without a reducer, one write replaces the value; multiple writes to the same key in one
superstep fail before state commit, identifying the writing tasks.

## Consequences

State remains directly inspectable, and merge behavior is visible in each key's declaration.
Runtime checks reject undeclared keys and unsupported values.

**Cost:** Hash state provides no static guarantee of value shapes. Runtime validation does not
establish application-level correctness; reducers and application tests must check those rules.
