# ADR-059 — No backward compatibility before 1.0

**Status:** Accepted 2026-10-01
**Date:** 2026-10-01
**Tier:** C
**Implementation:** Partial — `test/legacy_session_resume_test.rb` still requires a current build to read a pre-P8 session database, and session records tolerate the missing fields; that is the read-time tolerance this rule forbids
**Relates to:** [ADR-019](./adr-019-resume-is-graph-version-checked.md) (graph-state compatibility, a different contract), [ADR-001](./adr-001-framework-is-tamoz-the-reference-application-is-tamoz-agent.md)

Until 1.0, Tamoz keeps no compatibility machinery: no legacy-row readers, no compatibility shims or
aliases, no read-time tolerance for old rows. A database may be reset whenever a change needs it.
Migration ordinals still increase monotonically and stay checksummed.

## Context

Pre-1.0, every compatibility shim is code that exists only to preserve a past mistake, and each one
must be tested and reasoned about in every safety argument. No user depends on old rows yet. But
silently re-using a migration number, or editing an applied migration, would corrupt databases that
do exist during development.

## Decision

- A change may require a fresh database. Each new migration assumes a fresh schema; previous rows do
  not exist for it.
- No code reads, upgrades, or tolerates rows written by an earlier schema. Removed APIs and
  configuration keys fail loudly; no alias keeps them working.
- Migration ordinals are consumed monotonically, checksummed, and manifest-pinned; an applied
  migration is never edited.
- ADR-019's graph-version check still refuses to resume a checkpoint under an incompatible graph;
  that refusal is the behavior, not a migration path.

## Consequences

The code carries only the current shape. **Cost:** upgrading a development install may mean losing
its local state.
