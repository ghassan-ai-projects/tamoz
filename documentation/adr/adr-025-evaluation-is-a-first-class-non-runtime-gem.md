# ADR-025 — Evaluation is a first-class non-runtime gem

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

`tamoz-evals` owns executable invariant suites, behavioral cases, canonical artifacts, paired
baseline comparison, protected-holdout policy, and release gates. It can exercise every public
boundary, but **no runtime gem depends on it**. Safety/correctness are hard gates, not weighted
scores; model judges are fallible evidence after deterministic scorers; every evaluator change
starts a new lineage.

## Rejected alternatives

- evaluation as scattered test files — cannot own versioned corpora, baselines, judge lineage, or release evidence, or stop a self-improving agent redefining success.

## Verification

Verified against code: 2026-08-29 — `tamoz-evals` present; no runtime gem depends on it. `tamoz-evals-runner` is a *packaging* split, not a second decision: it ships the `tamoz-eval-runner` executable — the isolated harness/benchmark/treatment runner this ADR calls the "isolated evaluation worker" — separately from the `tamoz-evals` library (resolves audit O3).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
