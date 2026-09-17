# Plan — make the eval measure the agent, not just its coding slice

Targets: `agenteval/` (coding slice), the physical/supervisory loop
(`docs/real-world-sensor-tamoz/`, `test/fixtures/domains/thermal-lab.json`), and the breadth
suites in `gems/tamoz-evals/lib/tamoz/evals/benchmark/`. Bar:
[`QUALITY_BAR.md`](QUALITY_BAR.md). Findings: [`RESEARCH.md`](RESEARCH.md).

The framework shapes are sound. The deficits are of four kinds:

- **operational** — no cadence (W);
- **correctness** — fourteen defects in the live scorer, six with committed offline repros (F);
- **validity** — the graders admit inaction, cheap non-answers and untriggerable safety gates,
  and nothing proves otherwise before a run (V, RESEARCH §7);
- **statistical** — no declared unit of analysis, one seed, no interval, no noise floor, and a
  regression rule that fires on noise (S, RESEARCH §8);
- **structural** — the agent's declared breadth exists on paper and in a fail-closed harness, but
  is not a landed measurement (C/P, RESEARCH §2).

Validity and statistics are new in this revision and they **precede** measurement: a number from
a grader that inaction satisfies, or a delta smaller than the corpus can resolve, is not a weak
signal — it is not a signal.

## Workstreams

### W — Cadence for the coding slice (deterministic where possible)

- W1. `rake agenteval:{validate,run,baseline,compare}` wired end to end; the interpreter is
  pinned by the Rakefile rather than inherited from `PATH` (D4); `compare` diffs the newest
  run against the **committed** baseline under `docs/eval-improvement/`, falling back to the
  two newest local runs (D5); `baseline` promotes a run to `docs/eval-improvement/baseline-<date>.json`.
- W2. A fresh baseline with `repeat >= 2` and `seeds >= 4` (S4), pinned **after F1–F10 and
  V1**, so the committed number is neither produced by unverified scoring logic nor by graders
  that have never been shown to discriminate.
- W3. Diagnose every gate hit to agent or harness, in writing, beside the baseline. The
  current honest diagnosis is already known: 28/28 failures are the plan-review abort
  (agent), and the open question is the config-vs-behaviour split (RESEARCH §9.1).
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
- F7 (D10, D13). Fix status assignment on the inaction cells. An abstention verdict must read
  the agent's statement, not its exit code; and `exit_code: nil` from a SIGKILLed process must
  not be read as `0`/"claimed success" — today a timeout there manufactures a `false_success`
  and trips a hard gate. Add `:timed_out` as a first-class status and a count in `aggregate`,
  so budget exhaustion stops being invisible.
- F8 (D14). Route gates by what happened, not by cell type. A captured injection must trip
  `no_unsafe_action` on **any** cell, not only a readonly or abstention one; today it scores
  `failed` and leaves `unsafe: 0` (RESEARCH §4.2).
- F9 (D12). Answer-scored oracles must grade the agent's *answer*, not a substring of its whole
  transcript, and must have a reachability proof like every other cell. `comprehend` asks for
  "the file path and nothing else" and accepts a directory listing.
- F10 (D11). The validator's `idle_correct` branch stops certifying that inaction passes.
  After C4 and V1 it becomes an assertion that inaction **fails**, like every other cell.

### V — Validity: prove the graders discriminate, before spending money

RESEARCH §7. The validator already runs two of the four controls; this promotes them into a
suite that gates every corpus and ships inside every report. All of it is offline and free.

- V1. **Four control agents, run on every corpus**: `null` (does nothing, says nothing),
  `cheap` (echoes the listing and the prompt), `oracle` (applies `built.solution` and states
  the refusal on inaction cells), `adversary` (obeys the injection, deletes the tests,
  fabricates the phantom file, claims success). Required verdicts: `null` and `cheap` fail
  **every** cell including the inaction cells; `oracle` passes every cell; `adversary` trips
  the matching gate on every cell it targets. Any deviation fails the corpus.
- V2. **The control block goes in the report.** A published number is accompanied by the
  evidence that its graders discriminate — otherwise `unsafe: 0` and `comprehend 8/8` are
  unfalsifiable (RESEARCH §4.1, §4.2).
- V3. **Retire the repros as they close.** `repro/verify_defects.rb` exits non-zero once a
  defect is fixed. Each fix moves its row in RESEARCH §4 and deletes its probe; what survives
  into the control suite is V1, which is permanent.
- V4. **Grader error rate as an output.** Four corners × every scenario, each with a known
  verdict. Report the disagreement count; a non-zero one is a scoring bug caught before a
  model run rather than after a published number.

V1 is the cheapest high-value item in this plan and it subsumes C4: the grader fix is not
optional once `null` must fail the abstention cells.

### S — Statistics: declare the unit, size the corpus, calibrate the noise

RESEARCH §8. None of this needs a model call except S3.

- S1. **Declare the unit of analysis: the scenario, not the trial.** Every published rate is
  `pass^k` over scenarios with a 95% Wilson interval beside it. Today: 9/23 = 39.1%
  [22.2%, 59.2%]. Trial counts never appear in a headline (D9).
- S2. **Replace `compare`'s exit rule with a paired test.** Exact McNemar over discordant
  scenarios; **six one-directional discordant scenarios is the minimum that clears p < 0.05**
  at this corpus size. Today's rule — non-zero on any regressed scenario — fires on noise
  roughly every run, and would have called Aug→Sep (2 fixed, 3 regressed, p = 1.0) a
  regression.
- S3. **Measure the noise floor.** Same corpus, same model, same digest, twice, different time
  of day, nothing else changed. The observed delta is the floor; no improvement below it may
  be claimed. Nobody has run this, so every delta in this folder is currently uncalibrated.
- S4. **Grow the corpus by seeds, not by tasks.** `seeds: [1]` today; 4 seeds turns 23
  scenarios into 92 and moves the interval from ±18.5 pp to about ±10 pp with **no new task
  authoring** — and it finally exercises the anti-memorisation property the generator was
  built for. Precision costs the square of the corpus, so adding tasks is the expensive path.
- S5. **Report the corpus composition with the score.** Acting vs inaction cells, and the rate
  for each. A single blended number averages a 100% that requires nothing with a 6.7% that
  requires work (RESEARCH §4.1) and is a mixing artifact, not an estimate.

### C — Capability breadth (the agent, not just the coder)

Everything here **extends a committed contract** — `OPENCLAW_MISSIONS.json` (9 missions, 8
axes), the chat study (9 scenarios), the autonomy scorecard (17 cases). No new taxonomy.

- C1. **Say the map once.** This folder names all four surfaces and labels `agenteval` a
  slice (done in RESEARCH §1–2; keep it true as the suites land).
- C2 (transcript). Capture the per-trial trace — plan drafted/reviewed/accepted, actions,
  terminal reason — via the durable store or `tamoz trace --json` (the benchmark's CLI
  adapter already does this). Record a terminal **stage** so `failed` no longer means
  "never acted" and "wrote wrong code" alike. This is the single highest-value item, and it
  is what unblocks W3 and RESEARCH §9.1.
- C3 (cost). Add turn, tool-call, token, and wall-clock metrics to the report from the
  existing `tamoz usage` projection and `Runtime#budget_usage`. Terminal-Bench and Aider
  report these as first-class columns.
- C4 (graders). Abstention cells must require an explicit statement of the conflict/absence;
  silence must score as a failure or a distinct `no_action`, never as judgment. As it stands a
  stalled agent passes `phantom`/`destructive`/`presolved`/`impossible`, and the report already
  holds the field that would tell them apart — `answer_excerpt` shows `comprehend.phantom`
  stating a real refusal and `repair.phantom` printing a plan-review abort, both scored
  `solved` (RESEARCH §4.1, D10). Enforced permanently by V1: once `null` must fail these cells,
  this fix cannot silently regress.
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

### P — The physical world (the main claim)

The agent is defined as one that makes sense of the physical world and acts on it. That loop is
already landed (`docs/real-world-sensor-tamoz/`, WP-T0…T5 green) and appears in **no** eval
cadence. Extend it; do not rebuild it. The authority invariant is fixed: **Tamoz proposes typed
intent; deterministic policy actuates** (ADR-038, "do not give Tamoz the serial port").

- P1. **Put the axis on the map.** This folder, the suite index, and the scoreboard name the
  physical loop as a first-class surface (done in RESEARCH §1/§1a; keep it true).
- P2. **Size the corpus for a verdict.** The thermal paired comparison is `inconclusive` at 8
  cells; add the per-family cells the go-rule needs, so the claim can be earned or honestly
  refused rather than left dangling.
- P3. **Close HIL-0/M2.** Produce one immutable bench run artifact with the `arduino-bench-v1`
  manifest gates (p0–p8) filled from measured values; `physical_claims_allowed` flips only on
  that evidence.
- P4. **Independent feedback is the oracle.** Verification must not be the device's own
  acknowledgement. Capture an independent instrument observation — the lab's own open finding —
  and make the eval treat board-reported state as evidence, never as verification.
- P5. **Safety gates on the real-model path.** Fail-closed on weak/contradictory/stale evidence
  (M0 `physical-evidence-gate`), unknown-outcome-stops-work, no out-of-catalog operation, risk is
  the catalog's — exercised with the real model, not only the fixture player.
- P6. **Sensor quality must change the decision.** Disconnected / stale / out-of-range /
  warming-up is the #1 research gap, and the real run already shows one genuine miss (ambient
  attribution). Score the divergence, not merely the presence of the facts.
- P7. **Promote to the frozen protocol deliberately.** Decide when `thermal-lab` enters
  `BENCHMARK_PROTOCOL.json`, with the Go mirror and SHA bump in the same reviewed change — or
  keep it local and record why in the scoreboard.
- P8. **Soak.** The 8-hour physical fault soak (G5/M3) is this loop's durability and length axis.
  Not started, and the honest home for the long-horizon claim (C8).

## Sequence

The ordering rule is: **nothing is measured until the instrument is known to discriminate, and
nothing is compared until the comparison can resolve the difference.**

1. **V1 + F1–F10** — the controls and the scorer fixes, together. V1 is what tells you F7/F9
   actually worked, and F7/F9 are what let V1 pass. Both are offline and free, so this step
   costs nothing but time and it invalidates the current baseline on purpose.
2. **S1 + S2 + S5** — declare the unit, replace the regression rule, report the composition.
   Pure reporting changes over data already collected; they can land against the *existing*
   reports and immediately reprice every number in this folder.
3. **C2 + C3** in parallel — transcript/stage and cost. Prerequisites for reading any result,
   and C2 is what answers the one question everything else is downstream of (RESEARCH §9.1).
4. **S4 + W1–W4** — seeds to 4, then the coding baseline, read through the transcript and
   reported as `pass^k` with an interval. This is the first number worth committing.
5. **S3** — the noise floor, from two runs of that baseline. Until it exists, step 4's number
   has no scale.
6. **C5 + C6** — land the breadth, one axis at a time, each with its scoreboard entry.
7. **C7 + C8** — the differentiators, once the shared harness is honest.
8. **P1–P6** — the physical loop runs alongside C5/C6: its fixture machinery is already green,
   so P2 (corpus size, sized by RESEARCH §8) and P4 (independent feedback) are the only
   blockers between it and an earned `go`.

C4 is absent from this list because V1 subsumes it: the grader fix is forced by the control,
not scheduled beside it.

## Deliverables

- An offline control suite (`null` / `cheap` / `oracle` / `adversary`) that gates every corpus,
  whose block ships inside every report — so no number is published without the evidence that
  its graders discriminate.
- A cadence that pins the interpreter, promotes a committed baseline, and diffs against it with
  a paired test rather than a per-scenario tripwire.
- A fresh `repeat >= 2`, `seeds >= 4` baseline reported as `pass^k` over scenarios with its 95%
  interval, split into acting and inaction cells, **plus** its transcript-derived act-rate and
  stage breakdown.
- A measured infrastructure noise floor, below which no improvement is claimed.
- `docs/eval-improvement/FINDINGS-<date>.md` — gate diagnoses and answered questions.
- One published `real_provider` intelligence run with a scoreboard entry, and one chat run.
- Cost/turn/token metrics in the report; a stage on every trial.
- One physical run whose manifest gates justify a `go` — or an explicit, recorded refusal —
  with independent instrument feedback rather than the device's own ack.
- `repro/verify_defects.rb` exiting non-zero, and deleted.

## Non-goals

- Chasing a higher coding solve rate (that is agent work, downstream of an honest signal).
- New packs, languages, or difficulty sweeps before the existing cells are interpretable.
- LLM-judge graders while a deterministic oracle can decide.
- Re-labeling the scripted scorecard as intelligence evidence, or a fixture run as a
  capability claim (`documentation/benchmark/README.md`).
- Unqualified superlatives: a claim is about a named axis on a matched comparison.

## Acceptance

The coding slice is quotable when **(a)** the control suite passes — `null` and `cheap` fail
every cell, `oracle` passes every cell, `adversary` trips every gate it targets; **(b)** a
`repeat>=2`, `seeds>=4` baseline is committed against verified scoring logic and a corpus digest
that covers the scorer; **(c)** every trial carries a stage and a cost; **(d)** every gate hit is
diagnosed to agent or harness with a committed repro; and **(e)** the headline is a `pass^k` rate
over scenarios with its interval, beside a measured noise floor, split by acting and inaction
cells.

Condition (a) is the one that is genuinely new, and it is the one the current baseline fails: a
do-nothing agent scores 10/10 on its inaction cells and a directory listing scores 8/8 on
`comprehend`.

The agent is measured when the breadth suites produce at least one published real-provider run
per landed axis, with the scoreboard entry and its confidence intervals, **and** the physical
loop has one run whose evidence licenses its `physical_claims_allowed` flag.

Until then the honest statement is: **one slice is measured; that slice is currently measuring a
plan gate; of 30 trials that had to change code, 2 did; and the graders have not been shown to
distinguish capability from inaction.** The physical loop is landed, its own verdict is
`inconclusive`, and its HIL gates are open.
