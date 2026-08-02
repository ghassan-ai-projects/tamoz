# DR-3 — Memory evaluation substrate: the treatment harness

Status: design round — revision 2 (deep review ACCEPT-WITH-REQUIRED-CORRECTIONS on
revision 1; C1–C9 integrated; the decisive-metric section was rewritten; see
`docs/reviews/DR3_MEMORY_EVAL_PLAN_REVIEW.md`)
Origin: P11 plan review C2 (single biggest gap: the decisive metric was unmeasurable).
Verified facts bound this revision: `ScriptedModel` consumes a stage-keyed response
queue and IGNORES `system`/`prompt`; the smoke corpus runs in-process via
`AgentSmokeCorpus#execute` → `Tamoz::Agent.build` (no store, no memory config);
`SQLiteTraceRecorder` records SQL-boundary protocol events, not agent turns;
`Verifier` validates artifacts, not task outcomes; `AgentRunAudit` has no memory
awareness; no `RUN_*E2E` convention exists in this repo; no memory store exists in
`tamoz-agent` today.
Authoritative inputs: `MEMORY_DESIGN.md` §11/§7, the P11 plan §4 P11-ED, the eval seams
named below, the repo's actual conventions (documented operator runs + `TAMOZ_*` env
gates, not env-gated E2E tests).

## 1. Problem

The phase's decisive metric requires comparing four treatments on identical tasks and
proving that a recalled record changed a decision. The existing eval machinery is
deterministic and scripted; none of it measures retrieval. Revision 1 proposed
attributable-reuse in CI via a memory-aware mock — the deep review showed that would be
a **scripted tautology**: the mock never inspects the prompt, so the per-treatment
outcome difference is a script property, not a measurement.

## 2. Design decision (revised)

A `MemoryTreatmentProfile` in `tamoz-evals` that **wraps** the scorecard's per-case
runner (`AgentSmokeCorpus#execute`) per treatment — NOT a new harness. Reuse, with the
correct seams:

| Seam (exists) | Role in DR-3 (corrected) |
|---|---|
| `AgentSmokeCorpus#execute` | extended to accept `store:` + memory config args; drives each (case, treatment) cell in its own process with its own tmpdir/store file (C3/C4) |
| `ScriptedModel` | a new memory-aware sibling (`ScriptedMemoryModel`) — OR, per C1, the CI layer does NOT simulate decision-changing; it asserts injection correctness only |
| `Execution.events` (the agent turn stream: `:tool_started`, `:plan_accepted`, …) | gains a `:memory_recalled` event class (`memory_id`, `record_version`) — the ONLY attribution mark; prompt content captured where needed |
| `AgentRunAudit` | EXTENDED with the memory event class + sensitive/unauthorized recall counters (one auditor, one report domain) |
| `Verifier` + case schema | extended with the mandatory `treatments.expected_delta` block (C6); still the artifact verifier, not the outcome verifier |
| `Case`/`Evidence`/`Result`/`Artifact` + `CanonicalJSON` | pinned case/evidence/result artifacts with an explicit digest-exempt set (C5) |
| the sqlite scenario harness | NOT touched (its boundary-registry contracts are lease/request/checkpoint-specific; memory eval belongs on the agent-turn path) |

**The decisive metric is split (C1):**
- **CI layer — injection correctness (the reproducible gate number):** for each
  (case, treatment) cell, assert the decisive turn's prompt contains EXACTLY the
  records the store+policy should have injected (`:memory_recalled` marks in
  `Execution.events` match the retrieval-layer decision; sensitive records absent;
  no-memory run's prompt contains none). This is a real retrieval-layer test and is
  the phase gate's CI number. It does NOT claim layer value.
- **Live layer — attributable reuse (model-graded):** a documented, bounded, operator-
  run comparison (the repo's actual convention — documented manual runs, `TAMOZ_*`
  env gates; there is no `RUN_REAL_E2E` in this repo, C2). The four-treatment
  comparison runs against a real provider with real retrieval; helpful recall,
  wrong-memory harm, correction latency, and real cost are measured. The phase gate is:
  CI injection/plumbing pass AND a recorded, bounded, operator-run live pass with the
  four-treatment comparison and a fixed rubric. Live numbers are non-digest-reproducible
  by design (declared; never claimed as CI-reproducible).

**Corpus (revised):** (1) the existing agent-smoke corpus run under all four
treatments — the null baseline (all four identical is EXPECTED and asserted as the
no-regression control, not a pass-by-filler). (2) A memory corpus of tasks where memory
should matter, each with a **mandatory `treatments.expected_delta`** from
`failure_flip | cost_delta` (C6) — `null` is rejected for memory-corpus cases. Under
the mock, `cost_delta` is token/step COUNTS from the scripted queues (deterministic),
never runtime bytes.

**Treatments:** identical case + workspace, differing only in injected memory config:
(1) no memory (`memory_epoch: "none"`); (2) Experience only; (3) Experience + Knowledge;
(4) + promoted Wisdom. **Per-cell isolation (C4):** one store file per (case,
treatment), created in the cell's tmpdir; a pre-run store-digest assertion (each cell
starts from the pinned seed digest); seeding is deterministic admission with pinned
episode fixtures (reproducible, digest-pinned). Four treatments of one case NEVER share
a process or a store file (cross-treatment contamination would leak records into
no-memory/Experience-only cells and corrupt the delta).

**Outcome classes (C9):** per (case, treatment) — `pass | fail | insufficient`. A
`failure_flip` delta is asserted only when the baseline cell is a real `fail`; a
crashed/insufficient baseline makes the cell `attribution_incomplete` (excluded from
the credited-reuse denominator, which is always reported). No cross-treatment filling.

**Hard-zero sweep (C8):** E3 requires (a) at least one corpus case whose retrieval
genuinely matches the seeded sensitive record's searchable fields (the filter path is
EXERCISED, not vacuous), (b) codec decryption instrumentation asserting unauthorized
sensitive rows are never decrypted during a scan (the P11-B decryption-boundary
property), and (c) the no-memory cell's contribution declared vacuous-by-construction.

**Wisdom holdout (C7):** the protected partition lives OUTSIDE the promotion runner's
root, mode `0o700`, loaded only by a distinct verifier principal post-promotion. The
read-attempt test runs the REAL runner against the REAL path and asserts refusal at the
OS boundary (root confinement + absolute-path preflight), not a self-imposed
convention check.

## 3. Metrics

CI layer: injection correctness (exact-match assertions), mutation + safety counters
(via the extended AgentRunAudit), per-cell store digest stability, artifact digest
stability with the exempt set. Live layer: precision@k, helpful recall@k, task-success
delta per treatment, contradiction rate, stale-recall rate, sensitive-recall rate,
unauthorized-recall rate, wrong-memory harm, correction latency, retrieval token/cost
overhead, provenance coverage, promotion precision, protected-holdout delta,
deletion-propagation latency, successful attributable reuse. Denominators always
present; insufficient/attribution_incomplete cells reported, never hidden.

Hard-zero gates (fail the phase regardless of value): sensitive-recall rate and
unauthorized-recall rate > 0 in any treatment at any layer.

## 4. Failure model (reuse the existing family)

| Situation | Type (reuse) | Behavior |
|---|---|---|
| a treatment run aborts | `ExecutionError` | that cell `insufficient`; never filled from another treatment |
| artifact digest mismatch | `DigestError` | run fails; artifacts pinned |
| holdout leak detected | `InvalidArtifactError` (terminal) | promotion evaluation fails; candidate rejected |
| invalid case artifact (missing delta block) | `UnsupportedFormatError` | schema/verifier rejects |

No new error classes; the evals family (`ExecutionError`, `InvalidArtifactError`,
`DigestError`, `UnsupportedFormatError`) covers every case.

## 5. Tests (DR-3 acceptance, revised)

- E1 injection correctness: per-cell prompt-content exact-match assertions; no-memory
  cells contain no recalled records; sensitive records absent (CI).
- E2 attribution integrity: `:memory_recalled` marks present in the decisive turn AND
  the scripted outcome reflects the injection (mark AND flip, never flip alone);
  `attribution_incomplete` when the mark is absent.
- E3 hard-zero sweep: matching-attempt case + decryption instrumentation (C8);
  no-memory cell declared vacuous.
- E4 holdout isolation at the OS boundary: real runner + real path refusal (C7).
- E5 artifact reproducibility: digest-stable artifacts with the declared exempt set
  (latency/timing); per-cell store digest pinned; two CI runs byte-identical on the
  non-exempt surface.
- E6 insufficient-cell honesty: crashed cell `insufficient`; `failure_flip` asserted
  only on a real-fail baseline (C9).
- E7 store isolation: per-cell store file; pre-run seed-digest assertion; a
  contamination attempt (treatment N's records visible to M's run) fails the
  assertion.
- E8 corpus discipline: memory-corpus cases all carry a non-null expected_delta;
  smoke corpus's all-identical null asserted as the control.

## 6. Consuming phases

- The DR-3 substrate and profile are implemented. P11-ED integrates the real P11
  `MemoryRepository` adapter into that existing harness; P11-E runs it. P11 must not
  create a second treatment substrate.
- P11-W uses the holdout mechanics for Wisdom promotion.
- P12-I2 reuses the paired-baseline/holdout machinery (same engine, candidate-shaped
  difference — DR-1's single promotion engine).
- P15-F folds the artifacts into the canonical evaluation corpus + signed decision
  (per the P15 plan revision 2's pin manifest).

## 7. Review checklist (re-review)

1. Is the CI number now honestly an injection-correctness test (no layer-value claim),
   and is the live pass operator-run and bounded?
2. Does the `:memory_recalled` event class + prompt capture exist as specified, or does
   the plan still imply an existing pattern?
3. Are per-cell stores and the seed-digest precondition specified to the point an
   implementer cannot share a store file?
4. Does the mandatory expected_delta block close the filler-case hole?
5. Do E1–E8 catch the six deep-review probes (store contamination, artifact drift,
   scripted-answer success, filler cases, never-matched sensitive record, holdout
   glob)?
