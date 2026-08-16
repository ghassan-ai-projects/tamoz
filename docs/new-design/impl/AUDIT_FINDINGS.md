# Audit — `docs/new-design` implementation vs. the design

Independent audit of the P1–P8 implementation against the plan (`PLAN_TAMOZ_LLM_REASONER.md`),
the ten-rule bar (§1), and the per-phase exit gates. Method: read the real code on both repos,
ran targeted gate tests at HEAD, and checked the falsifiable proofs the design itself states —
not the phase reports' self-assessment.

Scope note: the design is **cross-repo**. This repo (`tamoz`) is the Ruby side; the Go side lives
in the sibling repo `agentic-stream` (`/Users/ghassan/my-projects/agentic-stream`). Half the
strongest proofs (B1, B10, P4 validator) are Go-side and were audited there.

## Verdict

The implementation is **unusually faithful** to a demanding design. The hard architectural
invariants are enforced in code, not merely asserted, and I independently reproduced the
fixture-level gates on both sides. The project also does not overclaim: no fabricated benchmark
numbers, no intelligence claim, fixtures consistently labeled.

The gaps are about **evidence and one coupling deviation** — not faked mechanisms. One matters
more than the rest: the single real model call the whole plan rests on (P1) cannot be reproduced
from the repository.

## Verified genuinely implemented (spot-checked in code + tests green at HEAD)

| Bar | Claim | Evidence I checked |
|---|---|---|
| B2 | Episode is a real compiled graph | `episode_graph.rb` — real `Tamoz.graph` with nodes, `branch`, reducers, `Limits`. Not a shell. |
| B3 | One effect door | `episode_model_call.rb:54-67` — `reason` calls the model only through `EffectDispatcher.run(safety: :unsafe, logical_key:)`. Same for tools. |
| B4 | Nodes cannot emit model events | `episode_stream.rb:190-193` — `emit` **raises** on model-event types. Events cross only via `emit_stream_part`, and `situation_request.rb:504-517` fetches the journal record by `effect_key`, requires head `:succeeded`, and cross-checks **both** request and response digests before emitting. Categorical, not aspirational. |
| B9 | Hard-coded domain tables deleted | `ACTION_RISKS`, `RISK_ORDER`, `COMPENSATION_RISK`, `WITHDRAW_TYPES`, `DOWNGRADE_TYPES`, `family_for` are gone from `gems/` — only historical comments and the test-data domain remain. |
| B1 | Native executor never built on a tamoz route (Go) | `worker_runtime.go:122-140` — native executor constructed **only** when `WorkerSocket == ""`. A worker socket *is* the tamoz route. Go test green. |
| B10 / P4 | Go validates risk by **equality**, not ceiling | `validator.go:330-333` — `risk != entry.RiskClass → reject("risk_label_mismatch")`; ceiling checked separately. Closes the design's cited `validator.go:138-163` weakness. Go test green. |
| — | Fixed graph composed in process, no `--graph` in production | `bin/tamoz-stream-worker` composes `EpisodeGraph.build`; no `--graph FILE`. |

Tests I ran at HEAD (Ruby 3.3.11, fixture-labeled, no real model):
`stream_episode_fixed_graph` (6), `intent_authority` (5), `reconsider` (10), `skills_memory` (12),
`witness` (12), `crash_matrix` (2), `benchmark_controls` (14), `benchmark_harness` (23),
`benchmark_holdout` (5), `benchmark_protocol` (8) — **all pass**. Go `internal/runtime` and
`internal/decisions` — **pass**. The reports are not stale.

Honesty posture (a positive): `BENCHMARK_PROTOCOL.json` is a genuine freeze doc (digests, budgets,
metric *definitions*) with **no fabricated results**; no scorecard of fake numbers exists; the P1
real-model test **skips** without `RUN_REAL_E2E=1`. The `DecisionNodeBuilder`/`DecisionBuilder`
pair is a port delegating to an impl, not a duplicated brain.

---

## Findings

### F1 — The one real call (P1 / B8) is asserted, not reproducible from the repo — **CLOSED** (commit `a9e5bed`)

Fix applied: the real-model E2E now pins `gemma4:26b` (Ollama manifest
`5571076f3d70050487b26b341705799e0ab29b808164f90d20d4cf84f699d251`) with
`TAMOZ_REAL_MODEL`/`TAMOZ_OLLAMA_BASE` overrides, and commits the witness
bundle (endpoint log + receipt + digest summary, incl. the model manifest
digest) to `docs/new-design/evidence/p1-real-run/<utc>/` (`latest` symlink).
Two real runs reproduced the identical request digest
(`sha256:c84727f4…`) — the frozen frame makes the request bytes
deterministic; the response digest is witnessed fresh per run. The old quoted
digest `sha256:85689b8e…` is superseded (the frame evolved through P4–P8).
`P1_REPORT.md` is CLOSED and cites the bundle. A hosted-provider (deepseek)
run is deferred and documented in the report.

### F2 — P4 silently introduced a `tamoz-stream → tamoz-agent` dependency edge — **CLOSED** (commit `a9e5bed`)

Fix applied: `WATCH_TYPE` moved to `Tamoz::Core::INTENT_WATCH_TYPE`
(`gems/tamoz-core/lib/tamoz/core.rb`); `IntentCatalog::WATCH_TYPE` is now an
alias; `decision_builder.rb` (the only edge: 1 require + 6 references) uses
the core constant and no longer requires tamoz-agent. Enola snapshot at the
fixed tree confirms `decision_builder.rb` depends only on tamoz-core +
tamoz-stream errors; the baseline is re-pinned so a reappearance is graded.
`test/dependency_isolation_test.rb` gained
`test_decision_builder_loads_core_only_and_no_agent_edge`.

### F3 — B8's stated proof is not a code guard — **CLOSED** (commit `a9e5bed`)

Fix applied: the literal guard lives at `emit_model_events`
(`situation_request.rb`, the design's stream-artifact admission point) —
a receipt carrying a FORGED provider marker (`test`/`fixture`/
`local-model-fixture`) is rejected with `wire_refused_model_event/
forged_provider_marker` even with matching journal digests. Real fixture
receipts carry provider `ollama` + model `local-model` and are not
discriminated (structural separation does that); the guard's scope is
forged-marker rejection, stated plainly. Tests:
`test_audit_f3_forged_provider_marker_invalidates_the_artifact` and
`test_audit_f3_real_fixture_provider_is_not_discriminated`.

### P7 observation — **CLOSED** (commit `a9e5bed`)

`P7_REPORT.md` created — the standing honest statement (harness shipped, 14
controls green as fixture tests, holdout never run against a real model, no
intelligence claim licensed); `P7_PLAN.md` points at it. Future changes to
the P7 claim edit P7_REPORT only.

---

## Observations (not blockers)

- **P7 is built but never run.** Real harness code shipped (`gems/tamoz-evals/lib/tamoz/evals/benchmark/*`,
  `script/benchmark_*`) and the 14 adversarial-control *mechanisms* pass as tests, but there is
  **no P7_REPORT** and no committed results — the holdout was never executed against a real model.
  This is honest, but it means the claim ladder is genuinely capped at ~level 4: **no intelligence
  claim is licensed**, and the elaborate benchmark harness must not be read as evidence of
  reasoning. State this plainly wherever P7 is referenced.
- **`ci_full` is not green.** P1_REPORT itself notes 11 pre-existing raw-oracle failures at HEAD;
  the "rake ci green" claims are the fast gate, not the full durability/oracle gate. I did not run
  `ci_full`; the reports' own admission stands.
- **Recall caller version skew.** `bin/tamoz-stream-worker:92` pins the recall caller
  `graph_version: "1"` while the episode graph is `GRAPH_VERSION "4"`. Likely fine (memory-compat
  is a separate axis), but worth an owner glance.
- **Pre-existing repo-wide coupling (enola).** God-class/hotspot concentration on `Tamoz::Core`
  (133 dependents) and a 24-module coupled cluster. Not new-design-specific; not introduced here.

## Audit scope / limits

Verified by reading code on both repos and running targeted **fixture** test slices (all green).
I did **not**: run the real-model E2E (needs Ollama + a real model), run full `rake ci` / `ci_full`,
or execute the benchmark holdout. F1 is precisely about that missing, non-reproducible real-run
evidence.
