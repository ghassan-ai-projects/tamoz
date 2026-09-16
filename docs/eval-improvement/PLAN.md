# Plan — make the capability eval useful

Target: `agenteval/`. Bar: [`QUALITY_BAR.md`](QUALITY_BAR.md). Findings: [`RESEARCH.md`](RESEARCH.md).

The framework is sound; the deficit is operational — no cadence, a stale red baseline, no
reliability, undiagnosed gate hits. This plan closes the operational gap; it does not rewrite the
framework.

## Work

### W1 — Cadence and regression gate (deterministic, no model)
A single `rake` surface over the existing CLI, so the eval is one command and its regression check
is routine, not a habit:
- `rake agenteval:validate` — prove the corpus (reachable + non-trivial); the pre-money gate.
- `rake agenteval:run` — run the corpus, write a dated report under `agenteval/reports/`.
- `rake agenteval:compare` — diff the two newest reports; non-zero on any regressed scenario.
- A short runbook (`agenteval/README` or the guide) naming the env (`DEEPSEEK_API_KEY`, UTF-8
  locale) and the one-command flow.

### W2 — A fresh, reliable, committed baseline (live)
Run today's agent with `--modifiers all --repeat 2` and commit
`agenteval/reports/baseline-<date>.json`. This replaces the six-week-old red baseline with a current
one that carries a reliability signal.

### W3 — Diagnose every gate hit
For each `false_success` / `unsafe` / `harness_error` in the fresh run, trace it to **agent** or
**harness** and record the verdict in a findings note. A harness bug is fixed here (it is the eval
measuring itself); a real agent finding is written up and, if actionable, flagged for its own work
— it is out of scope to *fix the agent* in this pass, in scope to *trust the number*.

### W4 — Answer the research questions
From the fresh run, fill in [`RESEARCH.md`](RESEARCH.md)'s open questions: current solve rate and
gate status, whether the Aug findings reproduced, which cells are reliable vs flaky, and the weakest
task×modifier cells. Record them in a `FINDINGS-<date>.md` beside the baseline.

## Sequence

1. **W1** first — cadence is deterministic and unblocks a repeatable run.
2. **W2** launched in parallel (the live run is the long pole).
3. **W3 + W4** consume the run's report once it lands.

## Deliverables

- `rake agenteval:{validate,run,compare}` + runbook.
- `agenteval/reports/baseline-<date>.json` (committed) with `repeat >= 2`.
- `docs/eval-improvement/FINDINGS-<date>.md` — gate diagnoses + the answered research questions.

## Non-goals (see the bar)

Raising the solve rate, new packs/languages/difficulty sweeps, externally-witnessed release
evidence. Those come after a trustworthy, cadenced signal exists.
