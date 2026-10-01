# Retired decisions

Decisions no longer in force. Each keeps a tombstone file so its number still resolves, and one row
here: what it said, when it died, why, and what replaced it. Numbers are never reused.

| ADR | What it said | Retired | Replaced by | Why |
|---|---|---|---|---|
| **002** | v0.1 ships four runtime gems: `tamoz-core`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-agent`. | 2026-08-26 | [ADR-052](./adr-052-a-gem-owns-one-dependency-boundary-and-is-reached-only-through-its-facade.md) | `tamoz-agent` was decomposed into focused gems; the count became false. |
| **003** | Reuse `RubyLLM::Message` / `RubyLLM::Tool` through public APIs; keep a lossless durable codec. | 2026-08-26 | [ADR-048](./adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md) | RubyLLM left the runtime; the codec survives as `Tamoz::StateCodec`. |
| **004** | `Tamoz.seq` / `Tamoz.step` are the canonical composition API; `tamoz-chain` is deferred. | 2026-10-01 | — (withdrawn) | The API was never built; composition is the graph plus plain Ruby. |
| **012** | MCP is a deferred, post-v0.1 integration. | 2026-07-30 | [ADR-029](./adr-029-mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk.md) | MCP shipped natively through the official SDK. |
| **035** | Streaming input is a distinct first-class Ruby runtime owning admission, temporal state, and replay. | 2026-10-01 | [ADR-036](./adr-036-cognition-sees-only-a-sealed-situation-snapshot-never-raw-evidence.md), [ADR-055](./adr-055-two-repo-authority-split.md) | The continuous plane moved to Go; the surviving rule is ADR-036's. |
| **037** | Event time, backpressure, and effect-disabled replay are contracts of Tamoz's continuous plane. | 2026-10-01 | [ADR-055](./adr-055-two-repo-authority-split.md) | Those contracts belong to `agentic-stream`; Tamoz computes none of them. |
| **043** | Telegram v1 is deny-only; chat grant counters must stay zero; buttons are single-use, digest-bound references. | 2026-10-01 | [ADR-049](./adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md) | Evidence-gated approval replaced deny-only; the reference binding is stated in ADR-049. |
| **051** | RubyLLM is removed; message and tool fidelity are Tamoz-native. | 2026-10-01 | [ADR-048](./adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md) | One decision with the model transport. |

## Renumbered

| Was | Now | Why |
|---|---|---|
| A second "ADR-048" in `OBSERVABILITY_DESIGN.md` §18.7 (automated responses) | [ADR-050](./adr-050-automated-response-durable-evidence.md) | Two decisions held 048; the observability one took the next free number. |

## Next reads

- [`README.md`](./README.md) — the catalog
- [`../../docs/adr-review-2026-09-29/README.md`](../../docs/adr-review-2026-09-29/README.md) — the review that retired 004, 035, 037, 043, and 051
