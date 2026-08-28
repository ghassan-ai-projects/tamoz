# ADR-051 — RubyLLM is removed from the runtime; message and tool fidelity are Tamoz-native

**Status:** Accepted 2026-08-26
**Date:** 2026-08-29 (recording a change completed on 2026-08-26)
**Relates to:** ADR-003 (reuse RubyLLM public values — this ADR completes its supersession), ADR-048 (one digest-bound OpenAI-compatible transport), ADR-002 (gem set), ADR-004 (`Tamoz.seq`).

Tamoz no longer depends on `ruby_llm` in any runtime gem. The model boundary is
Tamoz-owned end to end. This ADR records a decision the code already made but the ADR corpus
never wrote down — the single largest divergence between the record and the tree.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

The project's original bet (GOAL.md) was to build "over `ruby_llm`": ADR-003 had
`tamoz-agent` pass `RubyLLM::Message` and `RubyLLM::Tool` through public APIs, and the
`react(llm:, tools:)` entry accepted a RubyLLM Agent or Chat. ADR-048 then replaced the
*model transport* with a kernel-owned, digest-bound OpenAI-compatible client and retired
`RubyLLMModel`.

But ADR-048 was scoped to the transport. The reality went further: **every** RubyLLM surface
— messages, tools, the Chat/Agent entry shapes — was replaced with Tamoz-native types, and
the `ruby_llm` gem was dropped from the dependency graph entirely. Nothing in the corpus
recorded that the framing "over `ruby_llm`" is no longer true. ADR-003's "superseded by
ADR-048" understated it: ADR-048 does not, by itself, explain why `RubyLLM::Message` and
`RubyLLM::Tool` are gone.

## 2. Decision

**No runtime gem depends on `ruby_llm`.** Message, tool, and content-block fidelity are
carried by Tamoz-native value types under `Tamoz::*`; the model wire boundary is
`Tamoz::Agent::ModelClientFactory` → the digest-bound transport (ADR-048). The durable codec
that ADR-003 required (lossless snapshots preserving tool-call ids, content blocks,
citations, attachments, and unknown provider fields) survives as `Tamoz::StateCodec` and is
now owned by Tamoz, not delegated to a third-party message type.

## 3. Consequences

- **Requiring `tamoz/graph` loads no LLM client and no `ruby_llm`** — invariant 11 is now
  true by absence, not just by discipline.
- One credential, failure, and projection path (ADR-048), with no second SDK's message model
  to keep in sync.
- The GOAL.md / design-v0.1 framing "a Ruby-native durable agent runtime over `ruby_llm`" is
  historical. product.md already states the current framing ("Not a provider SDK wrapper.
  Tamoz owns one digest-bound OpenAI-compatible transport").
- Cost: Tamoz now owns message/tool/content-block modeling it once borrowed. That surface is
  small and OpenAI-compatible by ADR-048, which bounds it.
- ADR-003 is fully superseded: its RubyLLM-passthrough half is retired here; its
  durable-codec half is retained natively.

## 4. Invariant linkage

- **Invariant 11** — `tamoz-graph` never loads an LLM client (now structurally guaranteed —
  no `ruby_llm` in the graph, agent, or any gemspec).
- **ADR-020 / sensitive-data** — the native message codec applies the same one redaction
  policy across checkpoints, streams, logs, and `inspect`.

## 5. Rejected alternatives

| Rejected | Why |
|---|---|
| Keep `ruby_llm` as the message/tool type even after retiring its transport | Two message models to reconcile; the durable receipt needs exact wire bytes ADR-048 owns, which a third-party type does not expose |
| A thin `RubyLLM::Message` compatibility alias | ADR-048 already ruled out compatibility aliases for the retired model; the same reasoning applies to the message/tool types |
| Leave the removal implicit under ADR-048 | ADR-048 reads as a transport decision; the disappearance of `RubyLLM::Message`/`Tool` needs its own record so the corpus is not silently wrong |

## 6. Verification

Verified against code: 2026-08-29 — `grep -rin 'ruby_llm\|RubyLLM::'` over `Gemfile`,
`Gemfile.lock`, every `gems/*/*.gemspec`, and all `gems/**/*.rb` returns **zero** matches.
The model seam is `Tamoz::Agent::ModelClientFactory` (enola: fan-in 8, the sole runtime
credential resolver per ADR-048). `Tamoz::StateCodec` carries the durable message codec.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [ADR-048 — digest-bound model transport](./core-decisions.md#adr-048--one-digest-bound-openai-compatible-model-transport)
- [`../reference/model-providers.md`](../reference/model-providers.md) — provider configuration
