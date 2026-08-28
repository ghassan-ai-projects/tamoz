# ADR-035 — Streaming input is a distinct first-class runtime

**Status:** Accepted 2026-07-30; **revised** by [ADR-055](./adr-055-two-repo-authority-split.md).
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-055 (see the [catalog](./README.md))

## Decision

Unbounded evidence does not enter `tamoz-graph` or a model directly — the load-bearing rule,
still in force. **What changed (ADR-055):** the continuous plane (channel admission,
temporal/keyed state, replay) is no longer the Ruby `tamoz-stream` gem — the P14 engine was
retired (MIGRATION_13) and that plane now lives in the separate Go `agentic-stream` runtime.
`tamoz-stream` is now the **episode worker**: a gRPC server the stream dials to run one
immutable episode against a sealed Situation snapshot.

## Rejected alternatives

- renaming token/tool streaming as bidirectional streaming and attaching sensor callbacks to a long-running chat — no temporal truth, bounded state, or deterministic recovery.

## Verification

Verified against code: 2026-08-29 — `tamoz-stream` present as the `EpisodeWorker`; see [`../design/streaming.md`](../design/streaming.md) and ADR-055.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
