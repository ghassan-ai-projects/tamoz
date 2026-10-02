# ADR-003 — Reuse RubyLLM public values; durable codec (RETIRED)

**Status:** Retired 2026-08-26 — superseded by [ADR-048](../adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md)
**Date:** 2026-07-30

This decision is no longer in force. It said `tamoz-agent` would pass `RubyLLM::Message` and
`RubyLLM::Tool` through public APIs and keep a lossless durable codec. RubyLLM was removed from the
runtime; the codec survives natively as `Tamoz::StateCodec`. ADR-048 states the model boundary.

- **Why it died:** [`RETIRED.md`](../RETIRED.md).
