# ADR-041 — Communication channels are a contract gem plus per-transport adapter gems

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (why transports are a closed set), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (the process that runs a transport)

`tamoz-comms` owns the channel vocabulary and seams and depends only on `tamoz-core`. Each channel kind
is its own gem that depends only on `tamoz-comms` and implements its interfaces; every line of a kind's
code lives there. The worker reaches a channel only through one nil-safe delivery sink and never makes a
channel network call.

## Context

The first transport (Telegram) could have lived inside the comms gem behind a lazy `require`. That
would leave the transport seam untested as a seam and put `net/http` in the load graph of everything
that only needs channel values.

## Decision

- `tamoz-comms` owns surface and message values, identity and admission policy, rendering, and the
  interfaces a kind implements: `Transport` (authenticate, poll, deliver, signal, fetch an inbound
  attachment), `Channel` (judge a descriptor, open the connection the gateway starts once it holds the
  lease) and `ChannelSetup` (add, check, announce, the gateway's variables), plus the structural
  `CommsStore` contract. It knows the grammar of channels, not their list: a kind is a lowercase name,
  a party is `<kind>:user:<id>` or `<kind>:<space>:<id>`, a surface consumes one `<kind>:…` update stream.
  It loads no HTTP client.
- Each kind (`tamoz-telegram`, `tamoz-talk`) is a separate gem depending only on `tamoz-core`,
  `tamoz-comms` and the standard library, holding its transport, its runtime and setup halves, pairing
  and checks. A setup sees only the environment variables it declares and its own state folder.
- The closed set of kinds (ADR-014) is one registry in `tamoz-agent-cli` (`CHANNEL_KINDS`), which loads an
  adapter only when a command needs it; no other library file names a kind, apart from the frozen ones
  (checksummed migrations, benchmark-protocol code) that `channel_kind_containment_test` counts, and only
  the registry loads one (`channel_dependency_test`); both read the kinds from the registry.
- The worker emits events to a `DeliverySink`; with no channel configured it is a null sink. Only
  the gateway (ADR-042) talks to a transport.

## Consequences

The contract gem stays dependency-free and every transport is tested against the same seam
(`transport_conformance`); a new kind is its gem plus one registry line, which a test-only loopback kind
proves end to end without either shipped adapter loaded. **Cost:** each kind is a Tamoz release
(ADR-014), and the interfaces were shaped by two kinds and one test kind.

## History

- 2026-10-10 (owner) — The channel kind's runtime and setup halves moved into its adapter gem behind `Channel` and
  `ChannelSetup`; the contract gem keeps a grammar instead of a list of kinds
  (`docs/channels-abstraction-2026-10-10/PLAN.md`).
