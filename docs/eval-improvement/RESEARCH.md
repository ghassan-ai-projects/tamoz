# Research — the current eval landscape

## Two eval systems, two jobs

| System | Job | State |
|---|---|---|
| `tamoz-evals` + `tamoz-evals-runner` | Deterministic verification: release-evidence schemas, scorecards, treatments; never touches a live model | Complete, CI-integrated, already useful as a **correctness gate** |
| `agenteval/` | Real-model **capability** measurement: generator tasks × adversity modifiers, metric vector + hard gates, `pass^k` | Well-designed, works today — but stale, red, and un-cadenced |

`tamoz-evals` is a gate on plumbing and safety invariants (fixture/scripted only, by design —
`documentation/benchmark/README.md`: fixture runs "are not evidence that a model is intelligent").
The thing that actually measures whether the agent is *good* is `agenteval`. That is the target.

## What agenteval already does well

- **Contamination-resistant**: tasks are generators (`task.generate(seed) -> Scenario`), so every
  run is fresh bytes, safe to publish, impossible to tune against.
- **Capability × adversity matrix**: 6 tasks (comprehend, repair, diagnose, implement, author_tests,
  docs) × modifiers (clean, noise, inject, phantom, destructive, presolved, impossible) — a few
  hundred lines generate the corpus.
- **Outcome-only oracle** that never enters the workspace; file bytes + exit codes, never narration.
- **Metric vector + hard gates**, not one number: `false_success == 0`, `unsafe == 0`,
  `destructive_executed == 0` fail a run regardless of solve rate.
- **`agenteval validate`** proves each scenario is reachable and non-trivial before spending money.
- **`agenteval compare`** reports per-scenario transitions (fixed / regressed) between two runs.
- The tamoz adapter runs the **real `tamoz` binary** against **DeepSeek**, approvals auto-granted
  and labelled as a measurement artifact.

Confirmed 2026-09-17: `agenteval validate --modifiers all` → **corpus valid, 23 scenarios**; a live
`comprehend.clean` pilot solved with all gates passing. The framework is healthy.

## Where it is not useful yet

1. **The only baseline is stale and red.** `agenteval/reports/baseline-20260805.json`:
   `decision: fail`, solve rate **45%** (10/22), **1 false_success**, **1 harness_error**, all
   undiagnosed. A red baseline nobody has revisited in six weeks is not a signal anyone trusts.
2. **`repeat: 1`.** The reliability axis (`pass^k` — solved on *every* trial) is the design's answer
   to a stochastic agent, and the baseline never used it (`trials_each: 1`).
3. **No cadence, no regression gate.** agenteval is a standalone directory. There is no rake target,
   no committed rolling baseline, and `compare` is not wired into any routine — so a regression is
   only ever found by someone remembering to look.
4. **Undiagnosed gate hits erode trust.** A `false_success` or `harness_error` that is actually an
   eval bug is worse than no eval; each hit must be traced to *agent* or *harness* before the number
   means anything.
5. **Coverage is one pack.** Six tasks, one language exercised (ruby), seeds:[1]. Headroom exists in
   the design (difficulty is a generation parameter) but is unused.

## Open questions the fresh live run answers

- Against **today's** agent (post self-healing/-improvement work), what is the solve rate, and do
  the gates pass?
- Do the 2026-08-05 `false_success` / `harness_error` reproduce? If so, are they agent or harness?
- With `repeat: 2`, which scenarios are *reliable* (pass on every trial) vs. flaky?
- Which task×modifier cells are weakest — i.e. where is the agent actually bad?
