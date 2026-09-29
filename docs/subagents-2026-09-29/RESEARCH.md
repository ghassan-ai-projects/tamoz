# Subagents — research

Date: 2026-09-29. Branch `improve-agent-memory` at `9cfff524`. Source inspection and
published evidence only; no code changed and no model run.

## 1. What Tamoz already has

### 1.1 `delegate_child_task` — a durable, fire-and-forget child thread

| Piece | Where | What it does |
|---|---|---|
| `ChildTask` | [child_task.rb](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task.rb) | Value object: content-addressed `child_id`, 4 KiB task, ≤ 32 capabilities, depth 0..8, concurrency 1..16, status machine `pending → running → completed/failed/unknown`, completion digest. `assert_narrowed_to!` refuses a child whose capabilities exceed the parent's or whose authority revision differs. |
| `ChildTaskDispatcher` | [child_task_dispatcher.rb](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task_dispatcher.rb) | The model-visible tool `delegate_child_task({task, capabilities})`. Only `local:*` capabilities, no credential-shaped values, depth/concurrency budget, `:idempotent` safety. Returns only `"Enqueued durable child <id>"`. |
| `CapabilityBinding` | [capability_binding.rb:48](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb#L48) | Registers the tool as an **action** (never discovery) when a `child_task_runtime` is supplied. |
| `WorkerRuntime` | [worker_runtime.rb:230](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L230) | Reserves a concurrency slot, stores the child, pins its authority binding (profile digest), enqueues a `:turn` request on a **new thread** whose id is the `child_id`. `session_for_child` ([:742](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L742)) builds a narrowed session: allowed tools only, no MCP, `memory: nil` ("a child's task is written by the parent model, so it can never stand in for the user"). |
| `Worker` | [worker.rb](../../gems/tamoz-agent/lib/tamoz/agent/worker.rb) | Reconciles child requests each poll, marks a child `running` on claim, settles it from the child thread's terminal view. |
| Approval | [base.yaml](../../gems/tamoz-approval/policy/base.yaml) | `child_task` is `local_execute`, asks every time, `grant_scopes: [once]`; the policy loader refuses a `:session` grant for it. |
| Tests | `test/agent_child_task_test.rb`, `test/agent_child_task_runtime_test.rb`, `test/agent_phase4_capability_test.rb`, `test/approval_engine_test.rb:177` | Identity, CAS transitions, narrowing, budget, adoption. |

What it does **not** do — the facts that decide the design:

1. **The parent never sees the child's result.** The child writes a completion *digest*.
   `adopt_child_task` ([:304](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L304)) records
   an adoption, but its only caller is a test. No session node reads a child's answer.
2. **It is not on the work route.** `WorkContext#toolbox_schemas`
   ([work_context.rb:105](../../gems/tamoz-agent-session/lib/tamoz/agent/work_context.rb#L105)) shows
   the model toolbox schemas plus probes and memory tools. `delegate_child_task` is not a
   toolbox schema, so `tamoz code` and `tamoz investigate` never offer it. Only the older
   deliberation routes (plan/review/execute) can reach it.
3. **It is not in the CLI.** `Cli#build_durable_session`
   ([cli.rb:634](../../gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb#L634)) passes no
   `child_task_runtime`; only `WorkerRuntime` does ([:1095](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L1095)).
4. It is a separate thread, so a child's approval ask, a `/cancel`, and a crash each belong
   to a different thread than the parent's. Joining a result back would need cross-thread
   parking and un-parking, answer routing, and stop propagation — none of which exists.

It is background task spawning, not a subagent a parent can use.

### 1.2 Durable subgraphs — the seam a subagent should extend

`tamoz-graph` already runs a compiled graph **from inside a node**, durably:

- `Compiled#call(input, context)` ([compiled.rb:132](../../gems/tamoz-graph/lib/tamoz/graph/compiled.rb#L132))
  → `SubgraphRuntime#call` ([subgraph_runtime.rb:17](../../gems/tamoz-graph/lib/tamoz/graph/subgraph_runtime.rb#L17)).
- The child checkpoints on the **parent's checkpointer and thread**, in its own namespace
  `[..., "subgraph", <task id>, <call index>, <graph name>, <definition digest>]`.
- Its `execution_id` is derived from parent execution + task + call index
  ([subgraph_runtime.rb:105](../../gems/tamoz-graph/lib/tamoz/graph/subgraph_runtime.rb#L105)); the run
  context carries it (`RunCoordinator#invocation_context`, and `WriterRunExecutor#build_context`
  on resume). `SessionEffects#logical_identity` keys every journaled effect on
  `execution_id`, so a child's model and tool calls get their own journal entries and replay
  from their receipts.
- The parent task id is a deterministic digest (`Planner`) and the subgraph call index
  restarts at 0 per task, so a re-run parent node looks in the same child namespace. There
  it resumes (`:running` → continue, `:paused` → interrupt, `:completed` → return the
  stored output).
- A child interrupt **bubbles** to the parent as a `{"kind" => "subgraph", ...}` interrupt
  and resumes by position.
- Parallel subgraphs sharing a checkpointer are supported.

How far this is proven: `test/graph_subgraph_test.rb` has 4 tests, all on the in-memory
checkpointer. **Untested:** a crash in the middle of a child, a finished child returned when
the parent node re-runs, and the SQLite store with `DurableRunner`. One concrete risk:
SQLite write leases are per (thread, namespace) with a TTL
([lease_operations.rb:47](../../gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb#L47)). After a
real `kill -9`, the child namespace's lease can outlive the root lease, so the recovering
parent can hit "thread namespace already has an unexpired lease". **No production code
calls subgraphs yet**, so the first caller must prove this path (PLAN R3).

`Tamoz::Cancellation::Stops` is keyed by `thread_id`
([session_work.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb)); a child on the
parent's thread sees the user's `/cancel` at its next step with no new wiring.

### 1.3 The work route pieces a subagent reuses

| Need | Existing piece |
|---|---|
| A tool-calling loop with budgets, repeat guard, compaction, spill | `SessionWork`, `WorkGate`, `WorkCompaction`, `Harness::LoopPolicy` |
| A harness tool that runs a journaled model call inside the gate | `update_plan` → `WorkTools#review` ([work_tools.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/work_tools.rb)) |
| Prompts and tool schemas as digest-pinned files | `Harness::PromptPack` + `gems/tamoz-harness/prompts/` |
| A per-surface system prompt | `WorkContext::SURFACES = %i[cli chat]` + `surface_cli.md` / `surface_chat.md` |
| Narrowed tools, no memory | `WorkerRuntime#build_child_session` (`allowed_tools:`, `memory: nil`) |
| A finish that must cite gathered evidence | `report_findings` + `Harness::FindingsReport` |
| The capability eval, controls, multi-session runner | `agenteval/` (`noise` modifier, `tamoz-code-small` 12K arm, `SessionChain`) |

Two work-route behaviours a child must **not** inherit:

- `SessionWork#intake` seeds the surface from `conversation_transcript(context)` and
  `previous_turn_reader`, both keyed by `thread_id`
  ([session_work.rb:23](../../gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb#L23)). A child on
  the parent's thread would read the parent's conversation unless its intake is seeded from
  the brief alone.
- A completed work turn admits an Experience record (`SessionMemory`, [session_memory.rb:88](../../gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb#L88)).
  A child's turn must admit nothing.

## 2. What the field has learned

| Source | Finding | What it means here |
|---|---|---|
| Anthropic, [multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) (2025) | Lead + parallel subagents beat single-agent Opus 4 by 90.2% on their research eval. Agents use ~4× chat tokens, multi-agent ~15×; token use explained 80% of variance. Works for breadth-first work that exceeds one context; **poor fit for coding with tight dependencies**. Early failures: spawning 50 subagents for simple queries, duplicated work from vague briefs. Brief must state objective, output format, tools, boundaries, effort. Start evals with ~20 real cases; judge end state. | Read-only, breadth-first delegation. Structured brief. Measure over-delegation and cost, not only success. |
| Cognition, [Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents) (2025) | "Actions carry implicit decisions, and conflicting decisions carry bad results." Share full context; do not split decisions. | Children never write. The parent keeps every decision that changes the workspace. |
| Cognition, [Multi-Agents: What's Actually Working](https://cognition.com/blog/multi-agents-working) (2026-04) | What works: **single-threaded writes with several agents contributing intelligence**; clean-context review agents (≈2 bugs found per PR, ~58% severe) beat shared-context reviewers. Parallel-writer swarms and weak managers of child agents still fail. | Two roles only: `explore` (read and report) and, later, `review` (fresh-context reading of the parent's change). |
| Kim et al., [Towards a Science of Scaling Agent Systems](https://arxiv.org/abs/2512.08296) ([blog](https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/)) (2025) | 180 configurations. Independent agents amplify errors up to 17.2×; a central orchestrator holds it to 4.4×. Coordination cost grows with tool count; gains vanish once the single agent is above ~45% success. Centralized coordination +80.8% on parallelizable tasks. | Orchestrator–worker only (the parent checks every result). Expect little gain on tasks the single agent already solves; the eval must include those as a no-harm check. |
| Cemri et al., [Why Do Multi-Agent LLM Systems Fail?](https://arxiv.org/abs/2503.13657) (NeurIPS 2025) | MAST: 14 failure modes in 3 groups (system design, inter-agent misalignment, task verification). Most common: step repetition (17%), reasoning–action mismatch (14%), not asking for clarification (12%). | Label failed trials with MAST groups. Measure step repetition directly: the parent re-reading what its child already read. |
| Claude Code [subagents](https://code.claude.com/docs/en/sub-agents) | Own context window, own system prompt, restricted tools, cannot spawn subagents, only the final message returns. | Same shape: depth 1, narrowed tools, bounded result. |

## 3. Conclusions

1. **Build subagents as a durable subgraph inside the work route**, not by extending the
   child-thread mechanism. The subgraph code path already has replay, resume, interrupt
   bubbling, and shared cancellation on one thread, but it has no production caller and is
   untested on SQLite under a crash. The child-thread path would need all of those built for
   a second thread. Proving the subgraph path is cheaper than building that.
2. **Children read; the parent writes.** Every source agrees parallel writers fail. A
   read-only child also avoids the one subgraph gap: an approval ask inside a child (the
   read tier is `allow`).
3. **The expected benefit is context isolation and cost, not raw reasoning.** The real route
   (`deepseek/deepseek-v4.1-flash`) has a 1,048,576-token window, so small tasks will not
   overflow. The benefit to measure is: fewer parent prompt tokens per step, fewer
   compactions, better success on noisy/large repositories, and grounded answers. The
   risk to measure is: more total tokens, over-delegation, and the parent ignoring or
   repeating its child's work.
4. **`delegate_child_task` stays out of this change.** Whether to retire it once subagents
   land is an owner decision (it is a cross-gem interface), recorded in PLAN.md.
