# P7 — Implementation plan: benchmark protocol, holdout, adversarial controls

Status: **implemented + reviewed, committing** — see P7_REPORT.md for the
honest standing statement: the harness ships and the 14 controls pass as
fixture tests, but the holdout was never run against a real model and no
intelligence claim is licensed (claim ladder capped ~level 4).

- Pilot gate: the harness now carries each cell's `label` through extract, so
  a fixture run can NEVER claim `go` (reproduced before: `verdict: go` on a
  1-cell fixture run; after: `inconclusive`).
- Cluster bootstrap: true cluster bootstrap (clusters resampled WITH
  replacement, all cells kept) — the 95% interval is now the same
  mean-over-cells estimator the point estimate is.
- Climate cells: facts use the domain's native vocabulary (zone_temperature
  etc.), so the grounding gate passes and the climate half is measured.
- decision_at: real terminal event time (was BASE_TIME fallback) — lead_time
  and the premature-decision stop rule are live.
- Failed cells: reported with status/reason, `unreported_attempt` violation,
  never disguised as `unknown` predictions.
- Baselines: run per scenario family with the protocol-frozen metric/alarm
  pair (the strongest non-LLM baseline now sees every family's signal).
- Holdout truth: derived from facts by the SAME preregistered family rules as
  the pilot (was a coin flip — unlearnable by construction); overwrite
  refused without --force; LeakScan shared, not re-implemented.
- Stop rules: report detects fabricated_evidence_reference, premature_decision
  and unreported_attempt; controls_passed is an explicit go-rule input; the
  harness enforces the fixture stop; the control gate covers the rest.
- go_native_executor: merge seam exists (Report accepts Go batch cells); the
  Go→Ruby cell adapter + driver for the holdout run is deferred with the real
  provider run (owner-run, env-gated).
- episode_composition: intent_catalog_sha256 derived from the passed catalog
  (was hardcoded to aquaculture — same latent bug class as the diagnosis fix).
- Test hygiene: control-2 no longer runs the whole harness (script main
  guarded by $PROGRAM_NAME); control-3 asserts differing decisions;
  control-10 does a real fence+1 redispatch; scramble control has a chance
  band; log-loss penalty asserted; Go batch failure path tested.

Bar: PHASE_P7_BENCHMARK.md in-scope + stop rules + go rule. Bars: B8, B10.
Claim: only if the go rule passes — **"Model X beats baseline Y on benchmark
Z"** (level 5). Anything less is a negative/inconclusive result, plainly.

## Architecture (delta from P6)

The benchmark is a FROZEN protocol + a measured harness + one consolidated
adversarial-control gate. Most of the 14 controls already exist across
P1–P6 (forged model event, dummy-request, tampered artifact, injection
corpus, crash matrix, novel domain, witness); P7 consolidates them into ONE
preregistered gate and adds the protocol artifact + the measurement harness.

- **`BENCHMARK_PROTOCOL.json`** (committed, frozen, hashed): the machine-
  readable protocol — build digests (sealed build), graph/prompt/skill/
  catalog digests, provider/model identities + settings, budgets, the case
  matrix, the scoring equations, the baselines, the thresholds, the stop
  rules, and the power/min-case numbers. A generator script
  (`script/generate_benchmark_protocol`) emits it; a test asserts it
  regenerates byte-identically (like the requirements manifest) and that the
  committed SHA-256 matches. Any change = a new version.
- **The harness** (`script/benchmark_run` + `gems/tamoz-evals/.../benchmark/`):
  drives N fixture/gated cases through the fixed graph, computes the frozen
  metrics (macro-F1, balanced accuracy, Brier, log loss, calibration, lead
  time, action utility, cost per cell) against the preregistered baselines
  (majority prior, random label, fixed threshold, z-score, first difference,
  moving median, nearest symptom, deterministic detector, Go native executor
  comparator), and reports the paired comparison + cluster bootstrap
  intervals. Every dispatch is intention-to-treat: first attempt scored,
  failures never replaced.
- **Holdout mechanics** (`script/benchmark_holdout`): cases generated AFTER
  the freeze with opaque identifiers + temporal cutoffs on every input; the
  model-visible bytes are scanned for truth leaks (a digest + a forbidden-
  token scanner); the scorer and worker run under separate credentials.
- **The consolidated control gate** (`test/benchmark_controls_test.rb`): runs
  ALL 14 adversarial controls through the real composed graph in one
  preregistered suite (wiring the P1–P6 control tests together) — the go
  rule's hard gates (evidence-reference validity, authority, grounding) at
  zero failures.
- **Cross-cell isolation**: each benchmark cell runs in its own composition
  (separate checkpointer, tenant, seeds) — no shared memory/receipts.

## Exit gates mapped to tests

1. The frozen protocol file + hash regenerate deterministically (a committed
   artifact test).
2. The control gate: all 14 controls pass through the composed graph (each
   wired to its P1–P6 test).
3. The harness computes the frozen metrics + baseline comparisons on a
   fixture corpus (deterministic — the fixture cells are the calibration
   set, labeled `pilot`, never pooled).
4. Holdout: the generation script's opaque ids + temporal cutoffs + the
   truth-leak scan are tested (a forged leak is detected).
5. The go rule is NOT claimed by any test — the harness reports
   negative/inconclusive when the (fixture) comparison doesn't beat the
   baseline; the real provider comparison is env-gated (`RUN_REAL_E2E`),
   and the report states the honest result.

## Tasks

### T1 — The protocol artifact
- `script/generate_benchmark_protocol` → `documentation/benchmark/BENCHMARK_PROTOCOL.json`
  (freeze fields: build digest via SealedBuild, the graph/prompt/skill/
  catalog digests, the provider identities, settings, budgets, the case
  matrix, the scoring equations, the baselines, the thresholds, the stop
  rules, the min-case numbers).
- A determinism test (regenerate → byte-identical) + a committed SHA-256
  pin test.

### T2 — The harness (fixture corpus = pilot)
- `gems/tamoz-evals/lib/tamoz/evals/benchmark/` — the metric functions
  (macro-F1, balanced accuracy, Brier, log loss, calibration, lead time,
  action utility, cost) + the baselines + the paired comparison scaffold.
- `script/benchmark_run` — drives the fixture cells through the composed
  graph, labels the output `pilot`, never pools.

### T3 — The control gate
- `test/benchmark_controls_test.rb` — the 14 controls wired through the
  composed graph (each control = a named test calling the existing
  P1–P6 gate tests' mechanisms, consolidated).

### T4 — Holdout mechanics
- `script/benchmark_holdout` — opaque case ids, temporal cutoffs, the
  truth-leak scan (a forbidden-token + digest check on the model-visible
  bytes); `test/benchmark_holdout_test.rb` proves a seeded leak is
  detected.

## Test mode labeling

All P7 harness/control tests are fixture-labeled (`pilot`); the real-provider
comparison is env-gated and NEVER claimed by a test.

## Deferred

- The actual real-provider benchmark run (the owner runs it with a real
  model + the witness gateway; the go rule's claim is made there, not in
  tests).
