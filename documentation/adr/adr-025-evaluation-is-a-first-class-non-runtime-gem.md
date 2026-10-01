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

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Evaluation as scattered test files | Cannot own corpora, baselines, judge lineage, or release evidence |
| One evals gem with harness and verifier together *(retrospective, 2026-10-01)* | The verifier must load without harness dependencies; the split keeps it minimal |

## Reopen when

A runtime feature needs evaluation results at run time (for example, live canary gating), which
would put an evaluator in the runtime's path.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only the runner depends on `tamoz-evals` | gemspecs | `test/packaging_test.rb`; source inspection of `gems/*/*.gemspec` | — |
| The evals gem loads only the verifier boundary | `tamoz-evals` | `test/dependency_isolation_test.rb` — `test_evals_loads_the_verifier_boundary_only` | — |
| The verifier enforces the artifact contract | `tamoz-evals` | `test/evals_verifier_test.rb` | "Safety is never weighted" and "every evaluator change starts a lineage" are design rules with no mechanical check |
