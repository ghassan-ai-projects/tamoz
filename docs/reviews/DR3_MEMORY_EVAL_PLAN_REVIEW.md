# DR-3 memory evaluation substrate design review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C9; the decisive-
metric section was rewritten).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/DR3_MEMORY_EVAL_PLAN.md` revision 1 against `MEMORY_DESIGN.md`
§11/§7, the eval seams (`ScriptedModel`, `AgentSmokeCorpus#execute`,
`SQLiteTraceRecorder`, `Verifier`, `AgentRunAudit`, `SubprocessRunner`), and the
repo's testing conventions.

## Findings and dispositions

| # | Sev | Finding | Disposition (rev 2) |
|---|---|---|---|
| C1 | Severe | CI-layer "successful attributable reuse" is a scripted tautology: `ScriptedModel` consumes a stage-keyed queue and ignores system/prompt; the delta is a script property | Decisive metric SPLIT: CI asserts injection correctness (prompt-content exact-match; `:memory_recalled` marks; sensitive absent) — a real retrieval-layer test; attributable reuse is LIVE-LAYER only (documented operator run, fixed rubric) |
| C2 | Severe | "Same definition at both layers" false; `RUN_REAL_E2E` does not exist in this repo | Live pass = documented operator run (repo convention); per-case budgets pinned; live numbers declared non-digest-reproducible |
| C3 | Severe | Seam table misattributes 3 of 6 seams (`SQLiteTraceRecorder` is a SQL-boundary tracer; `Verifier` is an artifact verifier; `AgentRunAudit` has no memory awareness; `SubprocessRunner` doesn't isolate treatments; smoke corpus runs in-process with no store) | Seam table re-derived: `AgentSmokeCorpus#execute` extended (store + memory config); new `:memory_recalled` event class in `Execution.events`; `AgentRunAudit` extended; per-cell tmpdir + store file + config home |
| C4 | Severe | Store contamination unaddressed (one namespace, four treatments in run order) | One store file per (case, treatment); pre-run seed-digest assertion; deterministic admission with pinned episode fixtures |
| C5 | Major | E5 identical-artifact-digests contradicts latency metrics | Digest-reproducible artifact with an explicit exempt set (latency/timing); everything else pinned incl. per-cell store digest + injected-record list |
| C6 | Major | Delta assertion undefined for baseline/co-success; no treatment/expected-delta field in the case schema | Mandatory `treatments.expected_delta` block (`failure_flip | cost_delta`; null rejected for memory-corpus); cost delta = scripted token/step counts |
| C7 | Major | Holdout enforcement conventional, not structural | Holdout partition OUTSIDE the runner's root, mode 0o700, distinct verifier principal; read-attempt test at the OS boundary |
| C8 | Major | Hard-zero sweep can pass vacuously (sensitive record never matched) | Mandatory matching-attempt case per sweep + codec decryption instrumentation; no-memory cell declared vacuous-by-construction |
| C9 | Minor | "Insufficient cell" doesn't interact with the delta assertion | Outcome classes pass/fail/insufficient; `failure_flip` asserted only on a real-fail baseline; attribution_incomplete excluded from the credited-reuse denominator |

Duplication findings: the plan was a second harness (now wraps the scorecard's per-case
runner); the sqlite scenario harness was the wrong seam (not extended); invented error
classes (now reuse `ExecutionError`/`DigestError`/`InvalidArtifactError`/
`UnsupportedFormatError`); hard-zero counters belong IN `AgentRunAudit` (extended).

## Held-out probes

Cross-treatment store contamination; artifact regenerates differently across CI runs;
treatment "succeeds" with zero real retrieval (caught only with mark AND flip);
filler corpus case with null delta; sensitive record seeded but never matched; holdout
loaded by the evaluator's own corpus glob.

## Status

Corrections integrated in `docs/DR3_MEMORY_EVAL_PLAN.md` revision 2. The P11 plan's
P11-ED section must be read together with this DR (CI number = injection correctness).
