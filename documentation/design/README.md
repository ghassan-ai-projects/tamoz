# Design

Public summaries of how Tamoz is designed and why. Each page below covers one subsystem and links to the authoritative record behind it.

## Two layers of design documentation

- **`documentation/design/*.md` (this directory)** — public summaries. Written for readers who want the shape, the contracts, and the reasoning without the full internal record. Every page states its source and links to it.
- **`docs/design-v0.1/`** (repository-internal archive) — the authoritative, CI-validated design record. It holds the full design documents (`GRAPH_DESIGN.md`, `MEMORY_DESIGN.md`, `SCHEDULER_DESIGN.md`, `MCP_DESIGN.md`, `STREAMING_INPUT_DESIGN.md`, `SELF_HEALING_DESIGN.md`, `SKILLS_DESIGN.md`, and the architecture, persistence, agent, and evaluation documents) and the 61-clause invariant contract (`INVARIANTS.md`). `rake design:validate` checks its local links, required documents, invariant numbering, README coverage, and stale disproven guarantees. The authoritative, maintained **decision catalog** is [`../adr/README.md`](../adr/README.md); the archive's former `DECISIONS.md` was migrated there and removed.

The archive remains the source of truth; it is repository-internal and is not
part of the public reading path. If a summary and the authoritative record
disagree, the archive wins; a summary that drifts is a documentation bug.

Current version: `0.1.0.alpha.1` (pre-release).

## The design package's reading order

The authoritative package defines a reading order from goals to evaluation. Summarized:

1. **Goals and review** — why Tamoz exists, what "done" means, and the critical findings that shaped the design.
2. **Architecture and translation** — gem boundaries, dependency rules, and every Python-idiom-to-Ruby answer.
3. **Core and graph** — `Context`, streaming, instrumentation, errors, concurrency; then the durable engine: state, super-steps, interrupts, effects, leases.
4. **Persistence** — the atomic checkpointer, effect journal, Store, records, and migration.
5. **Agent** — durable model/tool execution, approval, subagents, compaction; the reference application and end-to-end traceability. The historical RubyLLM design is retained in the archive with an explicit supersession notice.
6. **The capability subsystems** — memory, self-healing, MCP, scheduling, skills, streaming input.
7. **Invariants and plan** — the executable contract, risk-first milestones, evaluation, and the decision record.

If you have twenty minutes, the package suggests: GOAL → REVIEW → INVARIANTS → IMPLEMENTATION_PLAN.

## Design pages

- [graph.md](./graph.md) — the durable graph engine: BSP super-steps, interrupts, replay, subgraphs, checkpoints, durable-runner contracts, the no-LLM rule.
- [memory.md](./memory.md) — three-layer memory (Experience | Knowledge | Wisdom), epistemic kinds, scopes, transitions, retrieval, consolidation, and the durable index.
- [scheduling.md](./scheduling.md) — durable scheduling: schedule/occurrence values, the ScheduleStore contract, due occurrences into the request inbox, budgets, and misfire/overlap/DST semantics.
- [mcp.md](./mcp.md) — the governed MCP client/host: immutable server admission, catalog, invocation, supervision, security, and governed websearch.
- [streaming.md](./streaming.md) — the supervised episode worker: containment host, sealed digest-verified Situation snapshots, typed Decisions, and the reverse channel.
- [self-healing.md](./self-healing.md) — bounded self-healing: typed failures, the remediation matrix, the DR-2 durable circuit, promotion gates, verification and compensation.
- [skills.md](./skills.md) — portable Agent Skills: format, snapshots, loading, frontmatter, supply-chain promotion, and why compilation never executes.
- [observability.md](./observability.md) — the signal plane: closed versioned catalog, correlation identity, immutable signals, bounded recorders, the local journal, content policy, and OTLP export.
- [comms.md](./comms.md) — the channel/communications design: channel values, admission, the Transport seam, delivery, approval policy, decision records, and the Telegram transport.

Related: the decisions behind these subsystems are cataloged in [`../adr/README.md`](../adr/README.md).

## Next reads

- [`../overview/concepts.md`](../overview/concepts.md) — the core concepts these designs build on
- [`../architecture/overview.md`](../architecture/overview.md) — the runtime architecture
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract in public form
- [`../adr/README.md`](../adr/README.md) — architecture decision records
- [`../../docs/design-v0.1/README.md`](../../docs/design-v0.1/README.md) — the authoritative design package
- [`../README.md`](../README.md) — documentation home
