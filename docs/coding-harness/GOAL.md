# Goal — coding harness

Set 2026-09-23 by the owner: "start the impl and finish it all, set up a goal and quality
bar that the harness should meet, loop until it is done." Branch: `coding-harness`.

## The goal

Tamoz can take a multi-file coding task from the CLI (`tamoz code`) or from chat, work
on it in a durable, approval-gated, tool-calling loop whose context is managed the DSH
way, and finish it with a verified, honest report. An eval shows this with a real model.

Done means every row of [QUALITY_BAR.md](QUALITY_BAR.md) is met or recorded as an
owner-visible finding with evidence.

## Owner decisions

The owner started implementation without overriding the plan's recommendations, so
they stand as decided (2026-09-23):

| # | Decision |
|---|---|
| D1 | Native tool calls (OpenAI-compatible `tools`). |
| D2 | A living plan with a declared scope, reviewed once by the existing semantic reviewer; leaving the scope is a plan revision. |
| D3 | No arbitrary shell: configured checks plus a read-only argv allowlist from profile data. |
| D4 | Project `AGENTS.md` goes into the body as attributed, untrusted guidance; opt-in. |
| D5 | Gems `tamoz-context-engine` and `tamoz-harness`. |
| D6 | DSH compaction defaults, one compaction per turn, then hand off. |

## Loop

Work package by work package (PLAN.md §4). Each package: enola baseline → build →
tests → gates → sub-agent review → commit. Progress is recorded in
[STATUS.md](STATUS.md) after every package so a new session can resume from it.
