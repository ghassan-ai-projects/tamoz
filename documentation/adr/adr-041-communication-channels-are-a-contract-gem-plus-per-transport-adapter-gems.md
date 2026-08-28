# ADR-041 — Communication channels are a contract gem plus per-transport adapter gems

**Status:** Accepted 2026-08-10. *(Tier F.)*
**Date:** 2026-08-10

## Decision

`tamoz-comms` owns the channel vocabulary and seams (surface/message values, identity/admission
policy, rendering, the `Transport` adapter contract, the structural `CommsStore` contract) and
depends only on `tamoz-core`. Each transport is a separate gem passing the `tamoz-comms`
conformance suite; `tamoz-telegram` depends only on `tamoz-comms` and stdlib. The kind list is a
closed set; adding a transport is a `tamoz-comms` release, not a plugin. The worker integrates
through one nil-safe `DeliverySink` and never makes a channel network call.

## Rejected alternatives

- a single gem with a lazily-required Telegram backend — leaves the transport seam untested and forces `net/http` into the contract gem's load graph (ADR-014 stands).

## Verification

Verified against code: 2026-08-29 — `tamoz-comms` and `tamoz-telegram` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
