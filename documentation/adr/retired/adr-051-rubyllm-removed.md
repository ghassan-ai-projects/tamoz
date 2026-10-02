# ADR-051 — RubyLLM is removed from the runtime; message and tool fidelity are Tamoz-native (RETIRED)

**Status:** Retired 2026-10-01 — superseded by [ADR-048](../adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md)
**Date:** 2026-08-26

This decision is no longer in force as its own record. It recorded that no runtime gem depends on
`ruby_llm` and that message, tool, and content-block types are Tamoz-native, with `Tamoz::StateCodec`
as the durable codec. That is one decision with the model transport, so ADR-048 now states both.

- **Why it was retired:** [`RETIRED.md`](../RETIRED.md).
