# ADR-021 — Resume preserves execution identity; fork changes it

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (effects are keyed by these identities)

Work has three identities: an execution id per turn, a logical activation id per node run that
survives interrupt, retry, crash, and lease takeover, and an attempt id per invocation. Resume keeps
the first two; a fork or a new turn changes the execution id.

## Context

Resume, retry, crash recovery, lease takeover, and fork all re-enter "the same" work. Recovery must
reuse what already happened (effects, successful siblings) while a fork or an intentional rerun must
not inherit the source's effects. One id cannot do both.

## Decision

- `execution_id` scopes a turn. A new external turn, a fork from history, or a state edit based on
  history creates a new one.
- Within an execution, a node's logical activation id is stable across interrupt checkpoints,
  retry, crash resume, and lease takeover. Pending writes, interrupts, and effects key on it.
- An attempt id binds one invocation to its base checkpoint; the barrier accepts a result only from
  the current attempt.

## Consequences

A resumed turn reuses its recorded effects and successful siblings; a fork re-executes cleanly.
**Cost:** a two-level identity to reason about, and a fork that must replay effect-bearing work
needs an explicit decision to do so.

## Invariants

- 3 — deterministic task and commit order.
- 6 — state edits append a fork with a new execution id.
- 52 — logical activation identity survives interruption and retry.

## Threat model

**Asset:** the link between a recorded effect and the run that may reuse it. **Adversary:** crashes,
stale attempts, and forks.

| Threat | Mitigation |
|---|---|
| A fork reuses the source's effect receipts | A fork is a new request with a new execution id; effect keys include the request id, so they differ |
| A stale attempt's result is accepted | Barrier validates the attempt id against the base |
| A crash re-runs a successful sibling | Activation id is stable; its committed writes are reused |

**Residual risk:** none known beyond ADR-016's.
