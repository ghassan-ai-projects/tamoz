# ADR-019 — Resume is graph-version checked

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-059](./adr-059-no-backward-compatibility-before-1-0.md) (database schema compatibility is a different contract)

A checkpoint records the graph it was written by; resuming it under an incompatible graph fails
before any user code runs.

## Context

Graph definitions change between releases. A thread paused under one graph and resumed under
another can run new node code against old state shapes — a silent behavior change for an in-flight
run, possibly mid-approval.

## Decision

Each checkpoint stores the checkpoint protocol version, graph name, graph version, and definition
digest. Resume compares them with the running graph before reading state or calling a node; a
mismatch fails. An explicit migration appending a new compatible checkpoint would be the only way
past it; no migration tool exists today. This governs graph
state only. Database schema changes follow ADR-059: no legacy-row readers; a schema change assumes
a fresh database.

## Consequences

An in-flight thread either resumes under the graph it started with or stops loudly. **Cost:**
changing a graph strands its paused threads unless a migration is written; pre-1.0, the expected
path is to let them fail and start fresh.

## Invariants

- 22 — graph compatibility before resume.
- 18 — versioned, allowlisted records.

## Threat model

**Asset:** the meaning of an in-flight run. **Adversary:** a release that changed the graph.

| Threat | Mitigation |
|---|---|
| New code runs against old state | Identity check before state access |
| A checkpointer speaking another protocol | Refused at construction |
| Silent auto-migration | Migration must append an explicit new checkpoint |

**Residual risk:** the definition digest covers names, channels, edges, branches, and each node's
declared name and version — not node code. A node whose Ruby body changes without a version bump
resumes old checkpoints under new behavior, undetected.
