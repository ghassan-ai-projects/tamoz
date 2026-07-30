# Tamoz — Ruby agent framework, design v0.1

Status: architecture-reviewed candidate · Date: 2026-07-30 · No runtime code in this folder

A Ruby-native durable agent runtime, integrated with
[`ruby_llm`](https://github.com/crmne/ruby_llm), designed to carry a personal agent of the
Hermes / OpenClaw class.

Start with **[GOAL.md](GOAL.md)**.
The findings that changed this revision are in **[REVIEW.md](REVIEW.md)**.

## The stack in one picture

```text
  Tamoz Agent — the reference agent (CLI first)
  ─────────────────────────────────────────────────────────  app
  tamoz-agent      plan/review · durable ReAct · verify · memory · heal · learn
  ─────────────────────────────────────────────────────────  depends on ruby_llm
  tamoz-graph      StateGraph · BSP engine · interrupts · leases · checkpoints
  tamoz-core       Context · StreamPart · instrumentation · concurrency
  tamoz-sqlite     durable checkpoint · lease · effect-journal adapter
  ─────────────────────────────────────────────────────────
  ruby_llm        Chat · Agent configuration · Tool · provider normalization

  Development and release only:
  tamoz-evals     conformance · behavioral suites · baselines · release gates

  Accepted post-v0.1 packages:
  tamoz-stream · tamoz-mcp · tamoz-scheduler

  Deferred until a real consumer requires them:
  tamoz-chain · tamoz-rails · tamoz-activerecord
```

The hard rule that shapes everything: **`tamoz-graph` never loads an LLM client.** The graph
engine is a general durable-execution runtime that happens to be used for agents. That is
invariant 11, and it keeps the engine testable offline and reusable for non-LLM workflows.

The other load-bearing rule is equally important: **checkpoints make state durable, not
external effects exactly-once.** Effects use stable identities and idempotency when the
target supports them. An ambiguous non-idempotent effect becomes `:unknown` and requires
reconciliation; it is never retried blindly.

## Reading order

| # | Document | What it settles |
|---|---|---|
| 1 | [GOAL.md](GOAL.md) | Why, what "done" means, what we refuse to build |
| 2 | [REVIEW.md](REVIEW.md) | Critical findings, five-whys root cause, and resolutions |
| 3 | [ARCHITECTURE.md](ARCHITECTURE.md) | Gem boundaries, dependency rules, the layered stack |
| 4 | [RUBY_TRANSLATION.md](RUBY_TRANSLATION.md) | Every Python idiom → its Ruby answer, and the refusal list |
| 5 | [CORE_DESIGN.md](CORE_DESIGN.md) | `Context`, streaming, instrumentation, errors, concurrency |
| 6 | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) | The engine — state, super-steps, interrupts, effects, leases |
| 7 | [PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md) | Atomic checkpointer, effect journal, Store, records, migration |
| 8 | [AGENT_DESIGN.md](AGENT_DESIGN.md) | Durable ReAct over RubyLLM, tools, approval, subagents, compaction |
| 9 | [TAMOZ_AGENT_DESIGN.md](TAMOZ_AGENT_DESIGN.md) | The reference agent and end-to-end traceability |
| 10 | [MEMORY_DESIGN.md](MEMORY_DESIGN.md) | Experience, Knowledge, Wisdom, retrieval, promotion, and forgetting |
| 11 | [SELF_HEALING_DESIGN.md](SELF_HEALING_DESIGN.md) | Typed bounded remediation, verification, compensation, circuits |
| 12 | [MCP_DESIGN.md](MCP_DESIGN.md) | Native MCP host/server boundary, protocol profiles, security, and durability |
| 13 | [SCHEDULER_DESIGN.md](SCHEDULER_DESIGN.md) | Durable occurrences, time/DST, misfire, overlap, and delayed authority |
| 14 | [SKILLS_DESIGN.md](SKILLS_DESIGN.md) | Portable Agent Skills, snapshots, loading, scripts, and supply-chain promotion |
| 15 | [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md) | Unbounded evidence, Situations, physical action boundary, and replay |
| 16 | [INVARIANTS.md](INVARIANTS.md) | The 55-clause executable contract |
| 17 | [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | Risk-first milestones and kill criteria |
| 18 | [EVALUATION_DESIGN.md](EVALUATION_DESIGN.md) | Conformance, fault injection, benchmarks, security |
| 19 | [EVALS_DESIGN.md](EVALS_DESIGN.md) | The evaluation gem, artifacts, corpora, scoring, and release gates |
| 20 | [CHAIN_DESIGN.md](CHAIN_DESIGN.md) | Deferred composition proposal and promotion gate |
| 21 | [DECISIONS.md](DECISIONS.md) | ADRs and product decisions still needing owner input |

If you have twenty minutes: GOAL → REVIEW → INVARIANTS → IMPLEMENTATION_PLAN.

Run `ruby validate_design.rb` from this directory to check local links, required documents,
invariant numbering, README coverage, and stale disproven guarantees.

## Relationship to the existing research

The source-level study recorded in [SOURCE](SOURCE) completed chapters 1–4 and stalled on
quota before the design half. This folder is that missing half, written as design rather
than report prose.

| Planned report chapter | Status | Delivered here as |
|---|---|---|
| Ch 1 Method and sources | written | `research/…_sec01.md` |
| Ch 2 RubyLLM architecture | written | `research/…_sec02.md` — the style guide this design obeys |
| Ch 3 LangChain architecture | written | `research/…_sec03.md` — the criticism table drives our refusal list |
| Ch 4 LangGraph architecture | written | `research/…_sec04.md` — the 11 invariants become clauses 1–11 |
| Ch 5 Comparative synthesis | never written | [RUBY_TRANSLATION.md](RUBY_TRANSLATION.md) |
| Ch 6 The Ruby blueprint | never written | [ARCHITECTURE.md](ARCHITECTURE.md), [CORE_DESIGN.md](CORE_DESIGN.md), [GRAPH_DESIGN.md](GRAPH_DESIGN.md), [CHAIN_DESIGN.md](CHAIN_DESIGN.md), [PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md) |
| Ch 7 Hermes application blueprint | never written | [AGENT_DESIGN.md](AGENT_DESIGN.md), [TAMOZ_AGENT_DESIGN.md](TAMOZ_AGENT_DESIGN.md) |
| Ch 8 Roadmap and risks | never written | [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), [DECISIONS.md](DECISIONS.md) |

One correction to the research: chapter 4 and the Hermes brief treat "Hermes" as the user's
own unpublished agent, reconstructed from articles because no repository was found. A local
clone of the actual [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
now exists at `~/external-projects/hermes-agent`, alongside
[`openclaw/openclaw`](https://github.com/openclaw/openclaw). Both were read directly for
this design. The requirements in [TAMOZ_AGENT_DESIGN.md](TAMOZ_AGENT_DESIGN.md) are derived
from those two real codebases, not from a reconstruction — which retires the
medium-confidence caveat that the study's cross-verification flagged.

## Sources read for this design

| Source | Location | Used for |
|---|---|---|
| current `ruby_llm` | official docs + local research | Chat, Agent configuration, Tool DSL, streaming, callbacks; volatile provider/model counts are deliberately not pinned here |
| `langchain` / `langgraph` | `~/external-projects/{langchain,langgraph}` | Capability requirements and the invariant set (via research chapters 3–4) |
| `NousResearch/hermes-agent` | `~/external-projects/hermes-agent` | Agent-layer requirements: prompt-cache discipline, sessions, compaction, subagents, skills, gateway |
| `openclaw/openclaw` | `~/external-projects/openclaw` | Agent-layer requirements: runtime layout, harness boundary, tool policy, plugin/resource manifests |
| Model Context Protocol | [current specification](https://modelcontextprotocol.io/specification/2026-07-28), [2025 compatibility specification](https://modelcontextprotocol.io/specification/2025-11-25), and [official Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk) | MCP profiles, primitives, stateless evolution, authorization/security, and SDK boundary |
| Agent Skills | [open specification](https://agentskills.io/specification) | Portable `SKILL.md` format and progressive disclosure |
| `fugit` | [official repository](https://github.com/floraison/fugit) | Strict Ruby cron parsing, IANA timezone calculation, and explicit cron semantics |
| Agentic Stream | [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md) | Situation Runtime, continuous/episodic split, event time, admission, action, and replay |
| Apache Flink | [event-time concepts](https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/time/) | Event time, processing time, watermarks, late data, and source idleness |
| MQTT 5 | [OASIS standard](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html) | Transport delivery semantics and their application-level limit |
| OPC UA | [PubSub](https://reference.opcfoundation.org/specs/OPC-10000-14/1), [Safety](https://reference.opcfoundation.org/specs/OPC-10000-15/4) | Ordinary streaming versus independently engineered functional-safety communication |
| Industrial robot safety | [ISO 10218-1:2025](https://www.iso.org/standard/73933.html) | Explicit boundary between agent supervision and certified robot/system safety |
