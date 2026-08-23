# tamoz-agent-memory

The durable memory vertical for Tamoz agents: admitted memory records,
situation-scoped retrieval, consolidation of verified outcomes into wisdom,
record lifecycle (including deletion with receipts), and behavior transitions.
Extracted from `tamoz-agent`; the namespace stays `Tamoz::Agent::Memory`.

## Public surface

- **`Memory::Engine`** — the facade that assembles and hands out the
  sub-services: `admission` (`Admission` — policy gate; default rejection is a
  typed result value, never an exception), `retrieval` (`Retrieval`),
  `lifecycle` (`Lifecycle`, including deletion receipts),
  `consolidation` (`Consolidation`), `transitions`
  (`BehaviorTransition` + `TransitionRegistry`), and `wisdom` (`Wisdom`).
  `SituationRecaller` adapts recall to `Tamoz::Core::SituationRecall`.
- **Values**: `MemoryRecord` (frozen, digest-addressed via
  `MemoryRecordDigest`) and `VerifiedOutcomeReference`.
- **Error family** (all under `MemoryError < Tamoz::Agent::Error`):
  `MemoryPolicyError`, `MemoryProtectionError`, `MemoryConsolidationError`,
  `MemoryDeletionError`, `BehaviorTransitionClaimConflictError`,
  `BehaviorSnapshotUnavailableError`, `UnverifiedTransitionError`,
  `BehaviorVersionConflictError`.

## Dependencies

`tamoz-agent-kernel` (`EffectDispatcher`, `Event`), `tamoz-core`,
`tamoz-sqlite` (`SQLite::MemoryStore`), `tamoz-tools`. Nothing above this layer
leaks in: no session, worker, CLI, graph, comms, or approval code.

## Versioning

Ships in lockstep with the rest of the monorepo (`0.1.0.alpha.1` literal per
gem, hand-synced like every sibling).
