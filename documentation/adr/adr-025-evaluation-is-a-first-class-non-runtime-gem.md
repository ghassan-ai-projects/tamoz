# ADR-025 — Evaluation is a first-class non-runtime gem

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete

Evaluation lives in its own gems, outside the agent's dependency graph: `tamoz-evals` owns
artifacts, schemas, and the verifier; `tamoz-evals-runner` owns harnesses and benchmarks. No runtime
gem depends on either.

## Context

An evaluator inside the runtime can be changed by the thing it judges, and evaluation scattered
across test files cannot own versioned corpora, baselines, holdouts, or release evidence. A
self-improving agent (ADR-023) makes this a safety question: the judge must be out of reach.

## Decision

- `tamoz-evals` owns canonical artifacts, case/evidence/result schemas, digests, and the verifier.
- `tamoz-evals-runner` owns execution harnesses, scorecards, treatments, and benchmarks, and runs
  only from an explicit external input manifest.
- No runtime gem depends on either. Safety and correctness are hard gates, never weighted into a
  score. Model judges are fallible evidence that runs after deterministic scorers. Every evaluator
  change starts a new lineage.

## Consequences

The subject cannot reach its judge, and a release decision is reproducible from artifacts.
**Cost:** two more gems, and the standing discipline of keeping them out of the runtime graph.

## Invariants

- 28 — self-improvement is evaluated and reversible (needs an evaluator outside the subject).

## Threat model

**Asset:** the integrity of evaluation results. **Adversary:** a self-improving agent or a careless
change that lets the runtime influence its own grade.

| Threat | Mitigation |
|---|---|
| The runtime loads or edits the evaluator | No runtime gem depends on the evals gems |
| A weighted score hides a safety failure | Safety is a hard gate, not a weight |
| A judge model drifts silently | Evaluator changes start a new lineage |

**Residual risk:** someone with repository write access can change both subject and evaluator in
one commit; review, not architecture, catches that.
