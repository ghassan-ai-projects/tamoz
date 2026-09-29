# Subagents (2026-09-29)

| File | What it is |
|---|---|
| [RESEARCH.md](RESEARCH.md) | What Tamoz already has (the `delegate_child_task` child thread, durable subgraphs), what the field has measured, conclusions |
| [DESIGN.md](DESIGN.md) | The `delegate` tool: a read-only child work loop run as a durable subgraph inside the parent's turn |
| [QUALITY_BAR.md](QUALITY_BAR.md) | Checkable rows A–G with evidence; red-at-parent rule |
| [EVAL.md](EVAL.md) | Offline spec suite, pack controls, real-model subagent pack (on vs off) |
| [PLAN.md](PLAN.md) | Owner decisions D1–D8 and rounds R0–R8 |
| [FINDINGS.md](FINDINGS.md) | The real-model run: inconclusive (the model never delegated), costs and next steps |
| [STATUS.md](STATUS.md) | Row-by-row state, the parent commit, deviations from the design, round log |

In short: Tamoz can already spawn a durable child thread, but the parent never gets its
answer, and the work route (`tamoz code`, `tamoz investigate`) never offers it. The
proposal is a read-only `explore` subagent that the work loop calls like a tool. It runs
as a durable subgraph on the parent's thread and returns a bounded, grounded result. Writes
stay with the parent. It is opt-in until a real-model run shows it helps without costing
more on simple tasks.

Status: implemented and evaluated; opt-in. The real-model run was inconclusive (see FINDINGS.md).
