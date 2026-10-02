# ADR-037 — Event time, explicit backpressure, and effect-disabled replay are contracts (RETIRED)

**Status:** Retired 2026-10-01 — superseded by [ADR-055](../adr-055-two-repo-authority-split.md)
**Date:** 2026-07-30

This decision is no longer in force as its own record. It made event-time, watermark, lateness,
idleness, bounded state, at-least-once acknowledgement, and effect-disabled replay explicit
contracts of the continuous plane. That plane is now the Go `agentic-stream` runtime, and ADR-055
states the rule that matters on this side: Tamoz computes none of these and consumes a sealed
snapshot.

- **Why it was retired:** [`RETIRED.md`](../RETIRED.md).
