# Memory — next level (2026-09-28)

| File | What it is |
|---|---|
| [REVIEW.md](REVIEW.md) | Current state of working and durable memory, what is good, defects F1–F12, scorecard against HDBK-006 |
| [DESIGN.md](DESIGN.md) | The three layers, how data moves between them, navigation, when and how memory enters context |
| [QUALITY_BAR.md](QUALITY_BAR.md) | Checkable rows A–G with evidence; red-at-parent rule |
| [EVAL.md](EVAL.md) | Offline spec suite, retrieval corpus with controls, multi-session real-model memory pack |
| [PLAN.md](PLAN.md) | Owner decisions and implementation rounds R0–R7 |
| [STATUS.md](STATUS.md) | Round tracker and red-at-parent evidence |
| [RESULTS-20260928.md](RESULTS-20260928.md) | First real-model memory-pack run: memory-on vs memory-off |
| [probes/](probes/) | The two scripts behind the probe-confirmed findings; run with `ruby -Itest docs/memory-next-level-2026-09-28/probes/<file>.rb` |

Before this work (REVIEW.md) the governance was strong and the usefulness close to zero.
After it: full-text retrieval with a bounded Knowledge brief, Experience written by every
completed work turn, `remember`/`forget` on the user's own words, `recall_memory`, the
compaction checkpoint carried across turns, CLI memory, and a controlled evaluation. First
real-model run (RESULTS-20260928.md): excluding MP1, memory-on solved 7/8 trials against 2/8
for memory-off, with zero hard-gate trips in both arms.
