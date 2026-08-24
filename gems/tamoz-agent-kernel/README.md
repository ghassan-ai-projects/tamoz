# tamoz-agent-kernel

The deliberation substrate for Tamoz agents: the record, receipt, and effect
primitives the whole agent family is built from. Extracted from `tamoz-agent`
so the vertical capabilities (memory, healing, improvement, profile) depend on
a base layer instead of the full runtime.

## Public surface

- **Error taxonomy** (`Tamoz::Agent`): `Error`, `ProtocolError` (alias of
  `Tamoz::Core::ProtocolError`), `PlanRejectedError`,
  `SkillSnapshotUnavailableError`, `McpCatalogSnapshotUnavailableError`, and
  the catalog/receipt error classes defined in `agent/errors.rb`.
- **Value types**: `Event`, `Step`, `Plan`, `ModelReceipt`,
  `ReasoningDocument`, `EpisodeModelCall`/`EpisodeToolCall` receipts,
  `BehaviorVersion`, `SealedBuild`.
- **The loop engine**: `Deliberation` (plan/review/execute/verify document
  parsing and structural checks), `EpisodeFrameBuilder`, `EpisodeNodes`.
- **Seams**: `EffectDispatcher` (deterministic logical-key side effects),
  `WitnessGateway` / `WitnessVerifier` (provenance), `ReceiptBudgetController`,
  `EpisodeModelTransport` (digest-bound wire client).
- **Graph versions**: `GraphVersions` — the durable session-graph family
  constants (`GRAPH_VERSION`, `CURRENT`, `ADAPTIVE`, `COMPACTION`,
  `SUPPORTED_GRAPH_VERSIONS`), consumable without loading the session.
- **Catalogs**: `DiagnosisCatalog`, `IntentCatalog`, `SkillSet`.

## Dependencies

`tamoz-core`, `tamoz-tools`. Nothing above this layer leaks in: no session,
worker, CLI, graph, comms, or approval code.

## Versioning

Ships in lockstep with the rest of the monorepo (`0.1.0.alpha.1` literal per
gem, hand-synced like every sibling).
