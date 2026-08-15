# P7 — Benchmark: prove it or stop

Bar rules exercised: B8, B10.

## Goal

Answer one question honestly: does a real model beat the strongest non-LLM baseline on held-out
diagnosis? Preregistered, witnessed, controlled. No answer is also an answer — then we stop.

## In scope

- **Public pilot first.** Tuning and calibration on public scenarios. Permanently labeled
  `pilot`. Never pooled with holdout results.
- **Freeze.** Machine-readable `BENCHMARK_PROTOCOL.json`, hashed before the holdout runs:
  build digests, graph/prompt/skill/catalog digests, provider/model identities, settings,
  budgets, full case matrix, scoring equations, baselines, thresholds, stop rules. Any change
  after freeze = new benchmark version.
- **Holdout isolation.** Cases generated after freeze. Scorer and worker under separate OS
  credentials. Opaque identifiers. Temporal cutoffs on every input. Model-visible bytes scanned
  for truth leaks.
- **Mandatory adversarial controls** (all must pass):
  1. Forged model event → rejected.
  2. Fixture/fake provider in an intelligence cell → run stops.
  3. Output dependence: different witnessed responses → different decisions.
  4. Dummy-request attack → binding fails.
  5. Prefix-indistinguishable worlds → byte-identical frames (any difference = leak).
  6. Scrambled labels → accuracy collapses to chance.
  7. Correct detection before first-observable time → suspicious, can stop the run.
  8. Grounding: remove cited evidence / perturb irrelevant evidence / swap cause and confounder →
     posterior moves in the preregistered direction.
  9. Injection corpus (skills, memory, snapshots, corrections, tool results) → all fail closed.
  10. Crash/redispatch matrix → no duplicate provider call, no stale acceptance.
  11. Artifact tampering → verification fails.
  12. Cross-cell isolation → no shared memory, receipts, seeds.
  13. Shadow decision and post-kill decision → independently refused by Agentic Stream.
  14. Novel domain → fixed graph, zero Ruby, loaded-source provenance clean.
- **Baselines (preregistered).** Majority prior, random label, fixed threshold, z-score, first
  difference, moving median, nearest symptom, strongest existing deterministic detector, and the
  Go native executor as a separate architecture comparator. The primary comparison is against the
  strongest non-LLM baseline.
- **Metrics.** Diagnosis macro-F1 / balanced accuracy. Brier score and log loss on the full
  probability vector. Calibration and risk-coverage under abstention. Evidence-reference validity
  (fabricated-reference rate is a hard zero gate). Lead time vs first-observable time. Action
  utility with missed-catastrophe and false-action costs reported separately. Cost per cell.
- **Statistics.** Intention-to-treat: every preregistered dispatch counts. First attempt scored.
  Failures never replaced. Paired seeds across providers and baselines. Cluster bootstrap
  intervals. At least 30 independent primary cases per scenario-family × provider cell, or the
  power calculation's number.
- **Two providers.** Second provider includes a pinned local model. Two adapters prove protocol
  portability, not equal intelligence.

## Stop rules

Stop on any: truth leak, holdout access, fixture/fake provider, forged or missing witness record,
artifact mismatch, fabricated evidence reference, cross-cell memory, hidden domain code, silent
fallback, accepted risk mismatch, unreported attempt.

## Go rule

An intelligence claim requires ALL of:

- 95% paired interval beats the strongest non-LLM baseline by the frozen minimum practical effect.
- All safety/cost floors pass per scenario, not only in aggregate.
- Grounding and authority hard gates at zero failures.
- The full report and bundle reproduce offline.

## Allowed claim

Only if the go rule passes: **"Model X beats baseline Y on benchmark Z"** — scoped to the exact
provider/model cells that passed. Level 5 of 6. Anything less is reported as a negative or
inconclusive result, plainly.
