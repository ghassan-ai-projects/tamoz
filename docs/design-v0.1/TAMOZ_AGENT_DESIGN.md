# Tamoz Agent — the reference agent

A Hermes/OpenClaw-class personal agent, in Ruby, on the Tamoz stack. Its product name and
application namespace are fixed by the [ADR catalog](../../documentation/adr/README.md), ADR-001.

Tamoz Agent exists for two reasons. It is the thing you actually want. And it is the only honest
specification of the framework: every primitive in Tamoz is here because Tamoz Agent needs it, and
§4's traceability matrix is the proof. A framework without a demanding consumer grows
forty concepts and three rewrites.

## 1. Requirements, taken from the real systems

Read directly from `~/external-projects/hermes-agent` (Python, Nous Research) and
`~/external-projects/openclaw` (TypeScript, OpenClaw Foundation). Both converge on the same
architecture, which is useful corroboration: **one agent core, many surfaces, capability at
the edges.**

| Requirement | Hermes | OpenClaw | Tamoz Agent v0.1 |
|---|---|---|---|
| One core across CLI, TUI, gateway, desktop | `agent/` shared by `cli.py`, `gateway/`, `ui-tui/` | `packages/agent-core` shared by `src/cli`, `src/channels` | yes — one compiled graph; CLI is the v0.1 proof |
| Durable sessions, resume across restarts | `gateway/session.py`, session store | `src/agents/sessions/session-manager.ts` | checkpointer thread per session |
| Prompt-cache preservation | stated as the first design property | prefix-stable prompt assembly | invariant 16 |
| Context compaction | `context_compressor.py`, `conversation_compression.py` | `agent-hooks/` compaction safeguard | compactor node, §7 of AGENT_DESIGN |
| Tool approval / policy | `tools/approval.py`, `tool_guardrails.py` | `agent-tools*.ts` tool policy | `interrupt` + policy object |
| Subagent delegation | `delegate_tool.py`, `subagent_lifecycle.py` | ACP spawn runtime | namespaced subgraph on the inherited backend |
| Skills | `skills/`, `skill_bundles.py` | `skills/*.md` manifests | Agent Skills-compatible, content-addressed progressive loader |
| MCP tools | `tools/mcp_tool.py` + OAuth + watchdog | `agent-bundle-mcp-*` | accepted post-v0.1 `tamoz-mcp` design over official SDK |
| Scheduled runs | `cron/`, chronos contract | `src/cron` | accepted post-v0.1 durable occurrence → request-ledger design |
| Streaming physical/digital evidence | gateway event sources and background services | event-driven channels/monitors | first post-v0.1 `tamoz-stream`: immutable Situation → bounded episode |
| Multi-channel gateway | ~20 platforms | ~25 platforms | **v0.2** — one channel (Telegram) first |
| Interrupt and redirect mid-turn | active-turn redirect in `conversation_loop.py` | `turn-interruption.ts` | `Context#cancellation` + queued injection |
| Session search | FTS5 + LLM summarisation | session store queries | SQLite FTS over checkpoints, v0.2 |
| Three-layer durable memory | `curator.py`, `learning_graph.py` | memory host SDK + dreaming | Experience → Knowledge → evaluated Wisdom, v0.1 |
| Self-healing | recovery paths + tool guards | doctor/repair flows | typed bounded remediation + verification + circuits, v0.1 |
| Trajectory recording | `trajectory.py`, compression for training | audit + transcripts | stream tee to JSONL, v0.1 |

Tamoz Agent v0.1 proves the core through a CLI. TUI, gateway, and session search remain
post-v0.1 promotion candidates. Streaming input, MCP, and scheduling remain post-v0.1
implementation work but now have accepted contracts and release gates. `tamoz-stream` is
first because it enables the physical-world profile. Planning, plan review, verification,
three-layer memory,
bounded self-healing, and a bounded self-improvement loop are part of the first release
because they define how action, continuity, recovery, and behavior change remain safe.

## 2. Shape

```text
       CLI v0.1       TUI later      Gateway later             Cron later
        │              │                     │                  │
        └──────────────┴──────────┬──────────┴──────────────────┘
                                  │      surfaces: render + approve + own the terminal
                    ┌─────────────▼──────────────┐
                    │  Tamoz::App::Session       │  resolve thread, own the policy objects,
                    │  (thread_id, policy, roots)│  queue turns, tee the stream
                    └─────────────┬──────────────┘
                    ┌─────────────▼──────────────┐
                    │  the compiled Tamoz graph   │  model ↔ tools ↔ compact ↔ subagent
                    └─────────────┬──────────────┘
              ┌───────────────────┼────────────────────┐
        checkpointer            Store                tools
        (SQLite thread)   (Experience/Knowledge/Wisdom)   local · skills · MCP catalog

  physical source → tamoz-stream → immutable SituationSnapshot → stable request_id
  typed ActionIntent → current-state policy/interlocks → narrow effector → Outcome event
```

The boundary that matters: **surfaces do rendering, approval, and input. They contain no
agent logic.** Everything a surface does is consume `StreamPart`s and answer interrupts. A
new surface is a stream consumer and an approval responder, which is why adding Discord
after Telegram is a day rather than a refactor.

## 3. The turn lifecycle

```text
input arrives with stable request_id
  │
  ├─ session resolved: (surface, chat, user, thread) → thread_id
  ├─ a turn already running?
  │     ├─ yes, and this is a redirect → cancel current turn, inject, restart from checkpoint
  │     └─ yes, and this is a queue → append to the pending-input channel
  │
  ├─ evidence insufficient?
  │     └─ review bounded read-only discovery plan → gather evidence → persist citations
  ├─ draft an evidence-backed action plan with definition of done, risk, and verification
  ├─ review plan → revise, ask for material clarification, or accept a digest-bound version
  ├─ graph.stream(accepted_plan, thread:, request_id:) — lazy Enumerator
  │     ├─ :message_chunk  → surface renders tokens
  │     ├─ :tool_start/progress/end → surface renders tool cards
  │     ├─ :interrupt      → surface asks the human; resume with Command(resume:)
  │     ├─ :checkpoint     → nothing; already durable
  │     └─ :error          → surface renders classified error, agent may self-correct
  │
  └─ verify definition of done → record trajectory → propose bounded learning candidates
```

No user, cron, subagent, or learning task action is scheduled without an accepted review of
the exact plan version. New evidence may cause replanning, but execution resumes only after
the replacement plan is reviewed. Crash resume reuses the accepted checkpointed version.

Interrupt-and-redirect is the part that is easy to get wrong. The last committed barrier
remains durable and late task state cannot commit, but an external effect may still finish.
The effect journal reconciles that outcome before the redirect advances. The redirect has a
stable request id and enters the thread's durable input queue exactly once.

## 4. Traceability — every framework primitive earns its place

| Tamoz Agent need | Tamoz primitive | Where designed |
|---|---|---|
| Resume a session after a crash | checkpointer + append-only history | [PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md) §1–2 |
| Prevent two surfaces advancing one session | lease + fencing + compare-and-append | [PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md) §2–3 |
| Approve a dangerous shell command | `interrupt` via `throw` + resume by index | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) §7 |
| "Actually, do X instead" mid-turn | `Context#cancellation` + checkpoint at each barrier | [CORE_DESIGN.md](CORE_DESIGN.md) §2 |
| Avoid repeating an ambiguous command | effect identity + journal + `:unknown` | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) §8 |
| Ignore duplicate gateway/CLI delivery | stable request id + durable request inbox | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) §9 |
| Run 5 file analyses at once | `Send` fan-out + reducer merge at the barrier | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) §6 |
| Delegate research to a cheap model | namespaced subgraph + `Router` | [AGENT_DESIGN.md](AGENT_DESIGN.md) §6, §9 |
| Stay inside the context window | compactor node + `cache_epoch` | [AGENT_DESIGN.md](AGENT_DESIGN.md) §7–8 |
| Not multiply the bill by breaking cache | invariant 16, append-only message events, stable fixed prefix | [INVARIANTS.md](INVARIANTS.md) |
| Render tokens in the right TUI pane | `StreamPart#namespace` path | [CORE_DESIGN.md](CORE_DESIGN.md) §3 |
| Remember across sessions without treating chat as truth | Experience → Knowledge → Wisdom lifecycle over scoped Store records | [MEMORY_DESIGN.md](MEMORY_DESIGN.md) |
| Retrieve memory without leaking or obeying stale data | authorize-before-rank, epistemic/provenance metadata, separate token budget | [MEMORY_DESIGN.md](MEMORY_DESIGN.md) §8 |
| Recover known failures without broader damage | typed reviewed remediation, effect reconciliation, verification, compensation, circuit | [SELF_HEALING_DESIGN.md](SELF_HEALING_DESIGN.md) |
| Undo a bad turn | fork via `update_state`, reducers re-run | [GRAPH_DESIGN.md](GRAPH_DESIGN.md) §9 |
| Resume safely after a deploy | graph version + definition digest + migration | [ARCHITECTURE.md](ARCHITECTURE.md) §8 |
| Add a hundred skills affordably | content-addressed progressive disclosure and bounded catalog/search | [SKILLS_DESIGN.md](SKILLS_DESIGN.md) |
| Survive a hung MCP server | supervised source, pinned catalog, durable effect/elicitation boundary | [MCP_DESIGN.md](MCP_DESIGN.md) |
| Nightly unattended job | durable occurrence, non-widening grant, headless approval policy | [SCHEDULER_DESIGN.md](SCHEDULER_DESIGN.md) |
| Notice a changing physical situation without agent storms | event-time operators, immutable Situation, bounded cognition admission | [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md) |
| Act in the world without giving the model actuator authority | typed intent, current-state policy/interlocks, effect journal, Outcome evidence | [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md) §11 |
| Plan and review before every action | digest-bound plan/review records and execution gate | [AGENT_DESIGN.md](AGENT_DESIGN.md) §1.1 |
| Act intelligently rather than merely continue | evidence, uncertainty, proportional action, and verification policy | [AGENT_DESIGN.md](AGENT_DESIGN.md) §13 |
| Improve without silently changing itself | evaluated candidate registry, promotion policy, behavior versions, rollback | [AGENT_DESIGN.md](AGENT_DESIGN.md) §12 |

Read the other way, the matrix is a cut list. A row proves a requirement has a home; the
v0.1 scope gate in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) decides when its package
ships.

## 5. Surfaces

**CLI** (v0.1, first). One-shot and interactive. Approval is an inline prompt. Output is
plain text with optional colour. This is the surface the walking skeleton ships on because
it has the least rendering machinery between the framework and the truth.

**TUI** (post-v0.1). Multiline editing, slash commands, streaming tool cards, scrollback.
The pane routing comes from `StreamPart#namespace`. Ruby's TUI options are weaker than the
JS ecosystem's — this is a genuine risk, logged in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

**Gateway** (v0.2). One channel first (Telegram), because the second channel is what proves
the abstraction and the twentieth proves nothing new. A channel adapter implements: receive
a message with a `SessionSource`, send a message, edit a message (for streaming updates),
and present an approval. Four methods. Hermes' `SessionSource` — platform, chat, user,
thread, and the key-generation rules for DM vs group vs thread — is a good model and worth
copying closely rather than re-deriving.

**Scheduler** (post-v0.1). `tamoz-scheduler` owns strict time calculation and durable
occurrence delivery, not agent execution. A schedule pins an immutable payload, maximum
capability grant, behavior adoption, budgets, overlap/misfire policy, unattended approval,
and result delivery. Each occurrence enters the ordinary request inbox under a stable id;
the agent then performs the same plan/review/verify lifecycle as an interactive task. See
[SCHEDULER_DESIGN.md](SCHEDULER_DESIGN.md).

**Physical-world Situation input** (first post-v0.1 product milestone). A read-only
connector feeds `tamoz-stream`, not the agent. Only a persisted admission for an immutable
SituationSnapshot becomes a normal stable request. Agent output is a typed intent; a
separate current-state policy and external interlocks own dispatch. The first effector is a
simulator. See [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md).

## 6. Tools: the narrow waist

OpenClaw and Hermes both state the same rule, and it is the second half of the Hermes
design lens: **every core tool is sent on every API call, so the bar for a core tool is
high.** Tamoz Agent ships a small fixed set and pushes everything else to skills, MCP, or plugins.

Core (v0.1): `read_file`, `write_file`, `edit_file`, `list_dir`, `grep`, `bash`,
`delegate`, `load_skill`. Eight. Network fetch is promoted only with an explicit egress and
content-trust policy.

Read-only tools may run concurrently. File writes lock canonical paths and use atomic
replace. Shell runs are `:unsafe` unless the command wrapper can provide an idempotent or
reconcilable contract. Approval never substitutes for effect safety.

Everything else — image generation, browser control, calendars, home automation, the long
tail both reference systems accumulate — arrives as an MCP server or a skill. A skill costs
one bounded catalog entry and loads progressively; a visible tool costs a schema on every
request. Neither MCP metadata nor skill content grants authority. See
[MCP_DESIGN.md](MCP_DESIGN.md) and [SKILLS_DESIGN.md](SKILLS_DESIGN.md).

## 7. What Tamoz Agent v0.1 will not do

- No desktop app, no voice, no browser control.
- One channel, not twenty.
- No unconstrained self-modification. The v0.1 learner may propose and evaluate improvements,
  but capability, policy, prompt-hierarchy, evaluator, and code changes require human
  promotion.
- No generic auto-healer. Each active remediation rule has typed triggers, bounded authority,
  independent verification, a circuit, and `tamoz-evals` promotion evidence.
- No plugin system. Skills and MCP cover the extension need; a plugin API is a compatibility
  commitment worth deferring until the core stops moving.
- No Windows support in v0.1. macOS and Linux.
- No raw video-rate cognition, direct motor trajectory, PLC scan-cycle logic, medical-device
  control, or certified safety function. Physical-world v1 is supervisory.

## 8. The first milestone, concretely

The product proof — the thing that proves the stack — is one command:

```bash
tamoz "read the failing spec, fix it, and run the tests"
```

with: a CLI surface, mandatory plan/review/verification, Experience/Knowledge/Wisdom memory,
at least one evaluated bounded remediation rule, bounded improvement candidates, the eight
core tools, destructive tools gated behind authorization and approval, SQLite
checkpoints/leases/effects, bounded terminal streaming, and
`tamoz --resume <session>` recovering after `kill -9` at every tested seam. An ambiguous
unsafe shell effect pauses for reconciliation instead of silently running again.

If that works, the framework is real. If it needs a single reach-around into internals, the
framework has a seam in the wrong place and the design changes before anything else is
built.
