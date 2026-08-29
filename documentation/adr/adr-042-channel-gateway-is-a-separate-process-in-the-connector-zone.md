# ADR-042 — The channel gateway is a separate process in the connector zone

**Status:** Accepted 2026-08-10.
**Date:** 2026-08-10
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

If the worker — which holds the model credential, toolbox, and workspace — made the outbound channel call, the connector-zone boundary would be aspirational rather than structural.

## Decision

`tamoz comms serve` is the only long-running Tamoz process that talks to the channel transport.
It holds the transport credential, admits/normalizes inbound updates, writes the durable
disposition, and drains the delivery outbox; it never constructs a `Session`, loads a model
credential, opens a toolbox, or reads workspace files. Both processes share one SQLite runtime
DB so an admission and its request enqueue commit in one transaction.

## Consequences

A separate gateway process holds the transport credential and never constructs a Session, toolbox, or workspace root, and both processes share one SQLite database so an admission and its request enqueue commit together. **Cost:** a second long-running process to deploy and operate.

## Rejected alternatives

- the worker performing the send — an outbound network call in the process holding the model credential, toolbox, and workspace makes the connector-zone boundary aspirational.

## Verification

Verified against code: 2026-08-29 — `tamoz-comms-gateway` present; `Tamoz::Comms::Gateway` symbol.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
