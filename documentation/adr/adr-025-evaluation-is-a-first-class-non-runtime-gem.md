# ADR-025 — Evaluation is a first-class non-runtime gem

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Evaluation embedded in the runtime cannot observe behavior without changing it, and scattered test files cannot reproduce a release decision or protect a holdout from a self-improving agent.

## Decision

`tamoz-evals` owns executable invariant suites, behavioral cases, canonical artifacts, paired
baseline comparison, protected-holdout policy, and release gates. It can exercise every public
boundary, but **no runtime gem depends on it**. Safety/correctness are hard gates, not weighted
scores; model judges are fallible evidence after deterministic scorers; every evaluator change
starts a new lineage.

## Consequences

`tamoz-evals` owns corpora, baselines, holdouts, and gates and can exercise every public boundary, yet no runtime gem depends on it. **Cost:** an extra gem, and the standing discipline of keeping it out of the production dependency graph.

## Rejected alternatives

- evaluation as scattered test files — cannot own versioned corpora, baselines, judge lineage, or release evidence, or stop a self-improving agent redefining success.

## Verification

Verified against code: 2026-08-29 — `tamoz-evals` present; no runtime gem depends on it. The
`gems/tamoz-evals-runner` gem is a *packaging* split (it ships the tamoz-eval-runner executable
— the isolated harness/benchmark/treatment runner this ADR calls the "isolated evaluation
worker"), not a second decision (resolves audit O3).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
