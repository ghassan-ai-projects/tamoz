# ADR-003 — Reuse RubyLLM public values; durable codec (RETIRED)

**Status:** Retired — superseded by [ADR-048](./adr-048-one-digest-bound-openai-compatible-model-transport.md) (transport) and [ADR-051](./adr-051-rubyllm-removed.md) (RubyLLM removal).
**Date:** 2026-07-30 (retired 2026-08-26)

This decision is no longer in force. It said `tamoz-agent` would pass `RubyLLM::Message` and
`RubyLLM::Tool` through public APIs. RubyLLM was removed from the runtime entirely; the
lossless durable-codec half survives natively as `Tamoz::StateCodec`.

- **What replaced it:** [ADR-048](./adr-048-one-digest-bound-openai-compatible-model-transport.md) + [ADR-051](./adr-051-rubyllm-removed.md).
- **Why it died:** [`RETIRED.md`](./RETIRED.md).
