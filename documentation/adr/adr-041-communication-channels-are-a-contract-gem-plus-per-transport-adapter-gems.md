# ADR-041 — Communication channels are a contract gem plus per-transport adapter gems

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (why transports are a closed set), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (the process that runs a transport)

`tamoz-comms` owns the channel vocabulary and seams and depends only on `tamoz-core`. Each transport
is its own gem that depends only on `tamoz-comms` and passes its contract. The worker reaches a
channel only through one nil-safe delivery sink and never makes a channel network call.

## Context

The first transport (Telegram) could have lived inside the comms gem behind a lazy `require`. That
would leave the transport seam untested as a seam and put `net/http` in the load graph of everything
that only needs channel values.

## Decision

- `tamoz-comms` owns surface and message values, identity and admission policy, rendering, the
  `Transport` contract, and the structural `CommsStore` contract. It loads no HTTP client.
- Each transport (`tamoz-telegram` today) is a separate gem depending only on `tamoz-comms` and the
  standard library.
- The worker emits events to a `DeliverySink`; with no channel configured it is a null sink. Only
  the gateway (ADR-042) talks to a transport.

## Consequences

The contract gem stays dependency-free and every transport is tested against the same seam.
**Cost:** each transport is a Tamoz release (ADR-014).
