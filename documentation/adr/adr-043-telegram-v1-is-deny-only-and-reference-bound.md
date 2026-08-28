# ADR-043 — Telegram v1 is deny-only and reference-bound

**Status:** Accepted 2026-08-10; **amended by [ADR-049](./adr-049-telegram-approval.md).**
**Date:** 2026-08-10
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-049 (see the [catalog](./README.md))

## Context

A chat identity is weaker evidence than filesystem access to the 0700 runtime directory, so a channel button must not be able to release a withheld side effect.

## Decision

A chat identity is weaker evidence than filesystem access to the 0700 runtime directory, so v1
Telegram surfaces can deny an exact pending interrupt and cannot grant approval. A button
carries an action plus a single-use 128-bit reference; the gateway stores only its
domain-separated digest in an inactive prompt row that activates only after a durable send
receipt, and consumption is atomic against every stored prompt binding. No channel component
answers on a human's behalf; `chat_grants` and `headless_auto_approvals` must both remain zero.
Any future grant mode requires a new ADR, a threat model, and a step-up identity decision — the
bar ADR-049 §4 now defines, and whose invariants (INV-A..INV-E) it states.

## Consequences

Telegram v1 can deny an exact pending interrupt but cannot grant approval, and each button carries a single-use, digest-bound reference that activates only after a durable send receipt. **Cost:** the channel can stop work but not authorize it; any future grant mode requires a new ADR meeting the ADR-049 bar.

## Rejected alternatives

- reusing the worker's `(thread, occurrence, granted)` tuple for callbacks — it binds no actor, interrupt digest, expiry, or consumption.

## Verification

Verified against code: 2026-08-29 — The deny-only `chat_bound` path is in `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb`; the evidence lattice is ADR-049 (`gems/tamoz-approval`).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
