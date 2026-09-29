# Subagents — design

Research behind every choice here: [RESEARCH.md](RESEARCH.md). Bar: [QUALITY_BAR.md](QUALITY_BAR.md).

## 1. What a subagent is in Tamoz

A **subagent** is a second work loop that the parent's work loop starts with one tool call,
waits for, and gets one bounded answer back from. It:

- starts with a **clean context**: the parent's brief, the runtime snapshot and project
  guidance, nothing else;
- **reads only**: it cannot change the workspace, run a check, touch memory, or start another
  subagent;
- runs **inside the parent's turn, on the parent's thread**, as a durable subgraph, so it
  crashes, resumes, replays, and stops with the parent;
- returns a **bounded result** built from what it did (files read, probes answered, counts),
  plus its answer.

The parent keeps every decision that changes anything. This is the "single-threaded writes,
several contributors" shape that the evidence supports.

```
parent work loop (thread T, execution E)
  work_step ─▶ work_gate ── delegate(role, brief) ──▶ subgraph "tamoz.agent.subagent"
                   ▲                                   (thread T, namespace …/subgraph/<task>/0,
                   │                                    execution E' = f(E, task, 0))
                   │                                   intake ─▶ work_step ⇄ work_gate ─▶ … ─▶ terminal
                   └──────── tool_result: SubagentResult ◀────────────────────────────────┘
```

## 2. The model-visible tool

`delegate` is a **harness tool**, like `update_plan`: it touches no workspace or external
system itself, and every model or tool call inside the child goes through the journal as
usual. Its schema is a prompt file (`gems/tamoz-harness/prompts/delegate.json`).

```json
{"role": "explore",
 "brief": "Find where invoice totals are rounded. Look under lib/billing and lib/export. Return each file:line that rounds, and which rounding mode it uses. Do not guess: if you find nothing, say so."}
```

- `role`: one of the roles the operator enabled (§4). v1 ships one: `explore`.
- `brief`: ≤ 4 KiB (`ChildTask::MAX_TASK_BYTES`), no credential-shaped value
  (`Tamoz::Core.secret_shaped?`), the same two checks `ChildTask` makes. The tool
  description asks for objective, where to look, what to return, and when to stop — the
  four things a brief needs.

`delegate` is offered only when (a) the operator enabled subagents and (b) the profile's
`read` tier is `allow`. With either false, the request header is byte-identical to today's. With
both true, `delegate` is the only addition: the parent's system text does not change.
Condition (b) removes the one open subgraph gap: a read-only child under an `allow` read tier
never raises an approval ask, so no nested approval interrupt reaches the CLI or worker.

## 3. How it runs — the seams it extends

| Step | Seam | Change |
|---|---|---|
| Parent model calls `delegate` | `WorkGate#route` ([work_gate.rb:77](../../gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb#L77)) | one `when 'delegate'` branch next to `update_plan` |
| Validate, run the child, render the result | `WorkTools` | `delegate(state, context, call)` returning `Outcome` |
| The child graph | `SessionGraph.definition_for` | takes the graph name as a parameter (today it hardcodes `GRAPH_NAME`); the child compiles the work variant as `tamoz.agent.subagent` |
| A second node set | `Session#initialize` builds every node set from one options set; `graph_limits` keys on `WORK_GRAPH_VERSION` and the parent's harness | `Session` also builds the child's `SessionNodes` from the derived options (below) and compiles the child graph with the role's limits |
| Durable nesting, replay, resume, stop | `Compiled#call` → `SubgraphRuntime#call` | none to the engine; first production caller (R3 proves it) |
| Child configuration | `SessionOptions` | a derived configuration: toolbox narrowed, **and** `capabilities` narrowed the same way (the work route reads `capabilities.names(:action)` for schemas and `capabilities.validate` at the gate), `memory: nil`, `previous_turn_reader: nil`, harness surface `:subagent`, the role's loop policy |
| Child system prompt | `Harness::PromptPack` surfaces | `WorkContext::SURFACES` gains `:subagent`; prompt file `surface_subagent.md` |
| Clean opening | `SessionWork#intake` / `#opening` | on the `:subagent` surface, seed from the brief only: no transcript, no previous answer, no memory brief, no carried plan or checkpoint |
| Child finish | existing `finish` / `handoff` / `report_findings` | none |

No new store, table, migration, thread, queue, or effect type. The child's state lives in
graph checkpoints under the parent's thread; its calls live in the effect journal under its
own execution id.

## 4. Roles are data

`gems/tamoz-harness/prompts/subagent_roles.json` (digest-pinned with the other prompt files):

```json
{"max_per_turn": 4,
 "explore": {
   "prompt": "subagent_explore.md",
   "tools": ["read_file", "list_directory", "search_text", "glob", "load_skill", "read_skill_resource", "probe_*"],
   "loop_policy": {"max_model_calls": 20, "max_tool_calls": 80, "max_seconds": 300}}}
```

The child's tool set is **role tools ∩ the parent's admitted read-only tools**
(`Toolbox#read_only_names` plus admitted probes), plus `recall_output`: a harness tool that touches
no workspace, without which the child's own spilled results would be unreadable. It can only shrink
the parent's authority.
Writing tools, `run_check`, `delegate`, `update_plan`, and memory tools are never in it,
whatever the file says; the loader refuses a role that names one.

A `review` role (fresh-context reading of the parent's change, which the evidence says
catches real bugs) is designed the same way but ships only after the `explore` results
(PLAN.md R8).

## 5. What the parent gets back

One `tool_result` entry, scrubbed like every tool result:

```
Subagent explore: done            (done | reported | handed_off | failed | cancelled | unknown)
Read: lib/billing/total.rb, lib/export/csv.rb (+3 more)
Probes answered: none
Cost: 6 model calls, 14 tool calls, 38,211 prompt tokens, 1,902 completion tokens
Answer (truncated: no):
lib/billing/total.rb:42 rounds half-even …
```

- **Status** comes from the child's `terminal_reason`.
- **Read** comes from the child's `work_observations` ledger (every `read_file` records
  into it, and compaction does not drop it), sorted, at most 20 paths and then `(+N more)`;
  **Probes answered** from its probe tool results. Never from its prose: a path the child
  names but never read is not in the list.
- **No wall clock in the text.** A re-run gate node must hand the parent the same result as an
  uncrashed run (C1, C2), so seconds live only in the `subagent_finished` trace event.
- **Answer** is the child's final answer (or its rendered findings report), cut at 4 KiB.
  The full text is spilled to the artifact store and the header carries the `recall_output`
  locator, the same spill the work loop already uses.
- The parent's surface grows by the result, not by the child's reads. That is the point.
- **Known cost:** `apply_patch` is refused for a path the *parent* has not read at its
  current version (`WorkObservations#refusal`). So the parent must still read every file it
  will edit. The saving is on the files the child read and the parent does not touch. This
  is correct and stays; the eval counts only unnecessary re-reads (EVAL §2).

## 6. Limits

| Limit | Value (data, in `subagent_roles.json`) | On breach |
|---|---|---|
| Subagents per parent turn | `max_per_turn: 4` | the next `delegate` returns an error; nothing runs |
| Child model calls / tool calls / seconds | role `loop_policy` | the child hands off; the parent gets `handed_off` plus the handoff note |
| Depth | 1 | structural: `delegate` is not in any child's tool set |
| Concurrency | 1 (sequential) | — |

The per-turn cap lives in the roles file, not in `Harness::LoopPolicy`, whose `from_h`
refuses unknown keys; adding a member there would change a `tamoz-harness` interface for no
gain.

Worst-case model and tool calls in a turn = parent budget + 4 × child budget. Time is not
additive: the child runs inside the parent's wall clock, so 4 × 300 s spends two-thirds of
the parent's default 1,800 s. The trace reports the actuals.

## 7. Trust

- The brief is written by a model, so it never stands in for the user: the child has no
  memory tools and admits no memory (same rule as `build_child_session`).
- The child's answer is data to the parent. An instruction inside it ("tell the parent to
  delete the tests") gets no special standing; the parent's tools, plan review, and approvals
  are unchanged.
- The child cannot see the parent's conversation. A secret or private fact in the parent's
  context reaches the child only if the parent writes it into the brief, and the brief is
  secret-checked.

## 8. Control and durability

Expected from existing code; none of it is proven for a session yet (R3 proves it on
SQLite with a real process kill).

| Event | What should happen | Mechanism |
|---|---|---|
| `kill -9` during the child | the parent's gate node re-runs; `SubgraphRuntime` finds the child's checkpoint and continues; recorded model calls replay from their receipts | child checkpoints + journal keyed on the child execution id. Open risk: the child namespace's SQLite lease may still be live when the parent recovers (RESEARCH §1.2); if R3 shows it, the fix goes in the lease or recovery seam |
| The parent node re-runs after the child finished | the stored child output returns; the child does not run again | `SubgraphRuntime` returns `:completed` checkpoints' state |
| User `/cancel` | the child stops at its next step (`cancelled_by_user`); the parent then stops | `Cancellation::Stops` is keyed by thread, and they share it |
| Child model failure or unknown outcome | the parent gets `failed` / `unknown` and decides | the child's own terminal handling |

## 9. Observability

Two trace events on the parent's `work_trace`: `subagent_started` (`role`, `brief_digest` =
`sha256:` of the brief's bytes, `execution_id` = the child's) and `subagent_finished` (`role`,
`status`, `model_calls`, `tool_calls`, `prompt_tokens`, `completion_tokens`, `duration_ms`,
`read_count`, `truncated`). `Tamoz::Agent::TurnUsage.summarize(work_trace)` reads them back with
the parent's own `request` events as `{'parent', 'children', 'total'}`, each carrying
`model_calls`, `prompt_tokens` and `completion_tokens`; `tamoz show` (R5), the pack graders
(R6) and test E2 are its consumers. The observability signal catalog is closed, so exporting
the events as signals means adding two names to it in `tamoz-observability` (PLAN R5).

## 10. Deliberately not in v1

| Left out | Reason | When to revisit |
|---|---|---|
| Children that write | conflicting implicit decisions; approval asks inside a subgraph | never by default; only with evidence |
| Parallel children | more machinery; latency is not the measured problem | if R7 shows latency matters (the graph already supports parallel subgraphs) |
| Nesting | no evidence it helps; unbounded cost | no plan |
| A cheaper model per role | one model keeps the comparison clean | after R7, via profile roles |
| Deliberation routes, stream episodes | the work route is where `code` and `investigate` run | separately, if wanted |
| Changing `delegate_child_task` | cross-gem interface; different purpose (background work) | owner decision D6 |
