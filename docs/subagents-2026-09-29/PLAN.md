# Subagents — implementation plan

Research: [RESEARCH.md](RESEARCH.md). Design: [DESIGN.md](DESIGN.md). Bar:
[QUALITY_BAR.md](QUALITY_BAR.md). Eval: [EVAL.md](EVAL.md).

## Owner decisions needed before R1

Each has a recommendation. Nothing is built until these are confirmed.

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | Mechanism | **Durable subgraph inside the work route**, not the `delegate_child_task` child thread | The subgraph already has durability, replay, resume, interrupt bubbling and shared cancellation; the child thread has none of the return path (RESEARCH §1.1) |
| D2 | Can children write? | **No.** Read-only in v1 | Every source agrees parallel writers conflict; read-only also avoids nested approval asks |
| D3 | Depth | **1.** Children cannot delegate | No evidence nesting helps; bounded cost |
| D4 | Parallel children | **Not in v1.** Sequential | Latency is not the measured problem; the graph supports it if R7 shows a need |
| D5 | Default | **Opt-in** (`--subagents explore`, runtime `harness.subagents`) until G0–G3 hold | Same rule memory followed |
| D6 | `delegate_child_task` | **Leave untouched now.** Revisit retiring it after R7 | It is a cross-gem interface with a different purpose (background work); two delegation mechanisms is a smell the owner should settle with evidence |
| D7 | Child model | **Same model as the parent** in v1 | Keeps the on/off comparison about subagents, not about models |
| D8 | Cross-gem additions | **Accept:** `tamoz-harness` gains prompt files, `subagent_roles.json` and a `:subagent` surface; `SessionGraph.definition_for` takes a graph name; `tamoz-observability` gains two signal names | All additive; AGENTS.md asks for approval before any cross-gem interface change |

## Rounds

Order: eval first (red), then the code that turns each row green. One round = one
sub-agent-reviewed unit and one commit. AGENTS.md rules apply throughout: extend the named
seams, no compatibility code, prompts as files, no model call outside the journal.

| Round | Content | Bar rows | Seams touched |
|---|---|---|---|
| R0 | enola `generate_snapshot` + `set_baseline`. Offline spec + durability suites and pack controls written against the target; run at the parent; record the pending count and the R0 header digest (for B7) in STATUS.md. | all A–E pending; F1–F4 met on controls | `test/`, `agenteval/` |
| R1 | Child configuration and clean opening: `:subagent` surface, `surface_subagent.md`, derived `SessionOptions` (narrowed tools, `memory: nil`, no previous-turn reader), `SessionWork` opening from the brief only, the `tamoz.agent.subagent` compiled variant. | B1, B3, B4, B7 | `tamoz-agent-session` (`SessionOptions`, `SessionWork`, `WorkContext`, `SessionGraph` use), `tamoz-harness` prompts |
| R2 | The `delegate` tool: schema file, `subagent_roles.json` + loader checks, `WorkGate#route` branch, `WorkTools#delegate` calling the subgraph, result rendering, spill, per-turn cap, trace events. | B2, B5, B6, B8, B9, C4–C7, D1, D2, D4, E1, E2 | `WorkGate`, `WorkTools`, `Harness::PromptPack`, `Harness::LoopPolicy` data |
| R3 | Durability and cancellation proofs on SQLite with a real process kill — the subgraph path's first production use. Watch the per-namespace lease on recovery (RESEARCH §1.2). Any failure is fixed in the seam it names, not worked around. | C1–C3 | tests; fixes only if red |
| R4 | Probes inside a child and `report_findings` as its finish; decide whether a work-route investigation scenario joins the pack. | D3 | `WorkContext#probe_schemas` for the child surface |
| R5 | Opt-in surface: CLI `--subagents <roles>`, runtime-directory `harness.subagents`, worker runtime parity; `tamoz show` renders subagent events; observability signals if the catalog is closed. | A1–A3 on the full slice | `tamoz-agent-cli`, `tamoz-agent` (`WorkerRuntime` harness options), `tamoz-observability` |
| R6 | agenteval subagent pack: scenarios SA1–SA5, the five trace graders, eight controls that each write a synthetic session record (today's controls return only answer/exit code/mutations), validator, `rake agenteval:subagents:prove` / `:run`. | F1–F4 | `agenteval/` |
| R7 | Real-model run, both arms, both windows; findings note; STATUS.md. | G1–G7 | — |
| R8 | Conditional on R7: `review` role (fresh-context reading of the parent's change); parallel fan-out if latency showed up; owner decision D6. | new rows added before the code | — |

Gates per round: `rake ci` + `rubocop` + `enola check`; `ci_full` both locales for R2, R3 and R5
(durability-adjacent, the kill test in the slow lane, and CLI packaging). enola `diff_snapshot` against the R0 baseline after
R1, R2, R5; a new cycle or coupling is fixed before the round is presented.

## Risks

| Risk | Control |
|---|---|
| The model never delegates, or delegates everything | the tool description and `surface_*` guidance are prompt files tuned against the pack; G3 and the delegation-rate-by-tag table show it |
| Children cost more than they save | G3 bounds the trivial case; G6 reports tokens per solved scenario; default stays off until the owner reads it |
| The parent ignores the result and redoes the reading | G5 step-repetition ratio; if high, change the result format (it is a file) before anything else |
| A child's clean context misses a constraint the parent knew | that is the brief's job; SA3 is built to expose it (the majority style is a fact the brief must carry or the child must find) |
| The subgraph path has a latent bug (no production caller; engine tests are in-memory only) | R3 on SQLite with a real kill; the per-namespace lease is the first suspect |
| The parent must re-read files it will edit (observation ledger) | intended; G5 counts only re-reads not followed by an edit |
| Subgraph namespace or execution-id collision between two `delegate` calls in one turn | each call runs in its own gate-node execution with call index 0 under a different task id; C2 and a two-delegation test in R2 assert distinct child executions |
| A profile tightens `read` to `ask` | `delegate` is not offered (DESIGN §2); B7 asserts it |
