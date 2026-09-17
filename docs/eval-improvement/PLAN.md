# Plan — make the eval measure the agent, not just its coding slice

Targets: `agenteval/` (coding slice) and the breadth suites in
`gems/tamoz-evals/lib/tamoz/evals/benchmark/`. Bar: [`QUALITY_BAR.md`](QUALITY_BAR.md).
Findings: [`RESEARCH.md`](RESEARCH.md).

The framework shapes are sound. The deficits are operational (no cadence), epistemic (the
live suite measures the plan gate, not the agent — RESEARCH §4.1), and structural (the
agent's declared breadth exists on paper and in a fail-closed harness, but is not a landed
measurement — RESEARCH §2).

## Workstreams

### W — Cadence for the coding slice (deterministic where possible)

- W1. `rake agenteval:{validate,run,baseline,compare}` wired end to end; the interpreter is
  pinned by the Rakefile rather than inherited from `PATH` (D4); `compare` diffs the newest
  run against the **committed** baseline under `docs/eval-improvement/`, falling back to the
  two newest local runs (D5); `baseline` promotes a run to `docs/eval-improvement/baseline-<date>.json`.
- W2. A fresh baseline with `repeat >= 2`, pinned **after F1–F5**, so the committed number is
  not produced by unverified scoring logic.
- W3. Diagnose every gate hit to agent or harness, in writing, beside the baseline. The
  current honest diagnosis is already known: 28/28 failures are the plan-review abort
  (agent), and the open question is the config-vs-behaviour split (RESEARCH §7.2).
- W4. Answer the open questions from the run and record them in `FINDINGS-<date>.md`.

### F — Framework correctness (do before pinning any baseline)

- F1 (D1). `Verify.kills_mutant` must not credit a timed-out mutant run. One condition.
- F2 (D2, D3). Unknown task/modifier is a one-line error listing the known ids; the pack's
  `supports:` lists only modifiers that exist, or the missing three are implemented.
- F3 (D6). Decide the harness's versioning: either un-ignore `agenteval/`, or add a digest of
  `lib/**` to the corpus digest and bump it on scoring changes. Recommendation: un-ignore —
  the thing that judges the agent should be reviewable.
- F4 (D7, D9). `compare` refuses (or loudly qualifies) a run pair whose model/provider
  differs, and reports scenario-level `pass^k` totals rather than trial counts.
- F5 (D8). Pin `--session-dir` per trial so the eval stops writing threads into the
  operator's live store; this is also the seam that makes cost capture possible (C3).
- F6 (§5). Correct `DESIGN.md` and this folder to match the code: gate ids, modifier count,
  `no_capability`, cost axis, stage reporting, baseline location.

### C — Capability breadth (the agent, not just the coder)

Everything here **extends a committed contract** — `OPENCLAW_MISSIONS.json` (9 missions, 8
axes), the chat study (9 scenarios), the autonomy scorecard (17 cases). No new taxonomy.

- C1. **Say the map once.** This folder names all four surfaces and labels `agenteval` a
  slice (done in RESEARCH §1–2; keep it true as the suites land).
- C2 (transcript). Capture the per-trial trace — plan drafted/reviewed/accepted, actions,
  terminal reason — via the durable store or `tamoz trace --json` (the benchmark's CLI
  adapter already does this). Record a terminal **stage** so `failed` no longer means
  "never acted" and "wrote wrong code" alike. This is the single highest-value item, and it
  is what unblocks W3 and §7.2.
- C3 (cost). Add turn, tool-call, token, and wall-clock metrics to the report from the
  existing `tamoz usage` projection and `Runtime#budget_usage`. Terminal-Bench and Aider
  report these as first-class columns.
- C4 (graders). Abstention cells must require an explicit statement of the conflict/absence;
  silence must score as a failure or a distinct `no_action`, never as judgment. As it stands
  a stalled agent passes `phantom`/`destructive`/`presolved`/`impossible` (RESEARCH §4.1).
- C5 (breadth land). Bring `script/benchmark_openclaw_run` from fail-closed to one published
  `real_provider` run, and write `documentation/benchmark/scoreboard/INTELLIGENCE_SCOREBOARD.json`.
  Order by what only Tamoz measures: `governance` → `recovery` → `self_knowledge` →
  `external_tool_use` → `memory` → `parity`. The chat study follows the same harness.
- C6 (autonomy cases, real model). The 17 scorecard cases prove the machinery with a scripted
  model. Add real-model variants only for the cases whose *behaviour* is model-dependent —
  unattended completion, approval correctness, recovery, capability-availability honesty —
  and keep them clearly separate from the plumbing gate.
- C7 (healing / improvement). Evaluate the promotion pipelines as pipelines: self-healing
  remediation bounded and reviewed (ADR-028); self-improvement promoted only on a **distinct
  holdout** behind a human gate, with rollback measured (ADR-023). These are the agent's
  most distinctive claims and have no eval at all.
- C8 (horizon). Add task *length* as an axis (METR's lesson). Today every task is minutes;
  the agent's durability story is about long horizons, which nothing currently measures.

## Sequence

1. **F1–F5** — the scoring logic must be trustworthy before anything is pinned or published.
2. **C2 + C3** in parallel — transcript and cost are prerequisites for reading any result.
3. **W2–W4** — the coding baseline, read through the transcript.
4. **C4** — the grader fix, then re-run the coding baseline so the abstention cells mean
   something.
5. **C5 + C6** — land the breadth, one axis at a time, each with its scoreboard entry.
6. **C7 + C8** — the differentiators, once the shared harness is honest.

## Deliverables

- A cadence that pins the interpreter, promotes a committed baseline, and diffs against it.
- A fresh `repeat >= 2` baseline **plus** its transcript-derived act-rate and stage breakdown.
- `docs/eval-improvement/FINDINGS-<date>.md` — gate diagnoses and answered questions.
- One published `real_provider` intelligence run with a scoreboard entry, and one chat run.
- Cost/turn/token metrics in the report; a stage on every trial.

## Non-goals

- Chasing a higher coding solve rate (that is agent work, downstream of an honest signal).
- New packs, languages, or difficulty sweeps before the existing cells are interpretable.
- LLM-judge graders while a deterministic oracle can decide.
- Re-labeling the scripted scorecard as intelligence evidence, or a fixture run as a
  capability claim (`documentation/benchmark/README.md`).
- Unqualified superlatives: a claim is about a named axis on a matched comparison.

## Acceptance

The coding slice is quotable when (a) a `repeat>=2` baseline is committed against verified
scoring logic, (b) every trial carries a stage and a cost, and (c) every gate hit is
diagnosed to agent or harness. The agent is measured when the breadth suites produce at least
one published real-provider run per landed axis, with the scoreboard entry and its
confidence intervals. Until then the honest statement is: **one slice measured, and it is
currently measuring a plan gate.**
