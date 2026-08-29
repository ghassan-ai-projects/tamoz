# Retired & superseded decisions

Decisions that are no longer in force. Per [`ADR_QUALITY_BAR.md` §5](./ADR_QUALITY_BAR.md#5-catalog-numbering-and-status-rules),
a dead decision does not keep a full page — it collapses to one honest line here: *what it
said, when it died, why, and what replaced it.* This keeps the history one grep away without
cluttering the live catalog with pages nobody should follow.

Numbers are **never reused** for a different decision. A retired number stays retired.

## Superseded (replaced by a successor)

| ADR | What it said | Died | Replaced by | Why |
|---|---|---|---|---|
| **002** | "v0.1 ships four runtime gems: `tamoz-core`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-agent`." | 2026-08-26 | [ADR-052](./adr-052-agent-gem-decomposition.md) | The tree grew to 27 gems; `tamoz-agent` was decomposed into eight verticals. The "four gems" count became false. |
| **003** | "Reuse `RubyLLM::Message`/`RubyLLM::Tool` through public APIs; define a lossless durable codec." | 2026-08-26 | [ADR-048](./adr-048-one-digest-bound-openai-compatible-model-transport.md) (transport) + [ADR-051](./adr-051-rubyllm-removed.md) (RubyLLM removal) | The RubyLLM-passthrough half is retired — RubyLLM is gone entirely. The durable-codec half survives natively as `Tamoz::StateCodec`. |
| **012** | "MCP is a **deferred** integration strategy (post-v0.1)." | 2026-07-30 (detail) / shipped since | [ADR-029](./adr-029-mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk.md) | MCP is native at the edge via the official SDK and has **shipped** (`tamoz-mcp`, `tamoz-mcp-websearch`). "Deferred" is no longer true. |

## Renumbered (integrity fix)

| Was | Now | Why |
|---|---|---|
| A second "ADR-048" in `OBSERVABILITY_DESIGN.md` §18.7 — "automated responses act only on durable evidence." | [**ADR-050**](./adr-050-automated-response-durable-evidence.md) | Two different decisions had both taken number 048 (model-transport vs. observability automation). The observability-automation decision was renumbered to the next free number, 050. The model-transport decision keeps 048. |

## Notes

- The historical full text of ADR-001..048 lived in `docs/design-v0.1/DECISIONS.md`, which was
  **removed** on 2026-08-29 once its content was migrated here (the `rake design:validate`
  archive checks were updated to match). The authoritative copies are the per-ADR standalone
  pages, indexed in [`README.md`](./README.md); dead decisions are the rows above.
- The open product questions that shared the old `DECISIONS.md` (first physical environment;
  finishing the research report) were never ADRs and are now tracked in
  [`../roadmap.md`](../roadmap.md#open-product-questions), not here.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`AUDIT_2026-08-29.md`](./AUDIT_2026-08-29.md) — why each of these was retired
