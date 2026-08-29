# ADR-048 — One digest-bound OpenAI-compatible model transport

**Status:** Accepted 2026-08-26; **completed by [ADR-051](./adr-051-rubyllm-removed.md).**
**Date:** 2026-08-26
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-051 (see the [catalog](./README.md))

## Context

Keeping a second SDK/provider adapter means two credential, failure, and projection paths in production, and it cannot expose the exact wire bytes the durable receipt contract needs.

## Decision

The kernel-owned `ModelClientFactory` is the sole runtime credential resolver and constructs the
`EpisodeModelTransport`. Session, ephemeral, and episode model calls use the same canonical
request/response projection and durable effect boundary. The provider configuration digest binds
provider, model, endpoint, protocol, settings, profile digest, and safety posture — never
credential values. Native Anthropic and Gemini protocols are rejected in this phase; operators
on those families select the `openrouter` provider explicitly. No compatibility alias preserves
the retired `RubyLLMModel`.

## Consequences

One kernel-owned `ModelClientFactory` and a single canonical request/response projection back every model call, with a provider-configuration digest binding provider/model/endpoint/settings but never credentials. **Cost:** native Anthropic and Gemini protocols are not spoken directly — those families are reached via the `openrouter` provider.

## Rejected alternatives

- a second SDK adapter — cannot expose the exact wire bytes the durable receipt needs and keeps two credential/failure/projection paths in production.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Agent::ModelClientFactory` present; zero `RubyLLMModel` references (ADR-051 records the full RubyLLM removal).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
