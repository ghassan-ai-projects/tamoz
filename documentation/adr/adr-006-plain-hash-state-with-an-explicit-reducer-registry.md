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
