# Deep research (2026-09-30)

| File | What it is |
|---|---|
| [RESEARCH.md](RESEARCH.md) | What the field converged on, what Tamoz already has, the gaps, conclusions |
| [DESIGN.md](DESIGN.md) | The four phases, plan checkpoint, roles and personas, dynamic fan-out, page reads, the report on disk, stop rule, self-tuning, the `tamoz-research` gem |
| [QUALITY_BAR.md](QUALITY_BAR.md) | Checkable rows with evidence; red-at-parent rule |
| [EVAL.md](EVAL.md) | Offline fixture web, pack controls, real-model question sets and arms |
| [PLAN.md](PLAN.md) | Agreed decisions, the owner's approval, rounds R0–R9 |
| [STATUS.md](STATUS.md) | Row-by-row state, commits per round, deviations from the design |

## Agreed definition (owner, 2026-09-30)

Given an open question, Tamoz returns a **cited report** in which every material claim traces to a
source Tamoz actually fetched and read, with the supporting excerpt recorded. It gets there through
repeated search → read → reflect cycles, reports which sub-questions it covered, where sources
disagree, and what it could not establish. It is not one search plus a summary, and it is not the
code `explore` subagent.

Four phases: **scope** (brief, then the plan is shown to the user to accept, edit or stop) → **research** (fan-out of `research` children, in waves) →
**write** (one writer, the lead) → **verify** (every citation checked against its excerpt).

Agreed scope: web only in v1; one interface for CLI and chat that shows no internals; the plan is
shown to the user before any search; GLM-5.3-Flash (Z.ai) as the model; Brave Search as the real
provider; budgets are data that start as defaults and move with evidence,
through the existing human-approved improvement lifecycle. The final report is written to the file
system. Entry: `tamoz deep-research "<question>"` on the CLI, `/research <question>` in chat.
Search and page reads are adapters: Brave for search, and a direct reader (`nokogiri`) for pages. The research rules live in a new `tamoz-research` gem behind one facade, and gem boundaries
are absolute.

Status: planned; nothing built.
