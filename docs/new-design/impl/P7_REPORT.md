# P7 — Phase report: benchmark harness shipped, never executed against a real model

Status: **HARNESS SHIPPED — HOLDOUT NEVER RUN** (audit observation).

## Honest statement

- The frozen protocol (`docs/benchmark/BENCHMARK_PROTOCOL.json`, SHA-256 pinned
  and byte-identical regenerating), the fixture pilot harness
  (`script/benchmark_run`), the holdout generator (`script/benchmark_holdout`),
  the metric/baseline/comparison library (`gems/tamoz-evals/lib/tamoz/evals/benchmark/`),
  and the 14 adversarial-control mechanisms all ship and pass as FIXTURE tests.
- The holdout was **never executed against a real model**, and no
  `P7_REPORT` results were previously committed. The go rule is therefore not
  claimed — the claim ladder is capped at ~level 4 (plumbing + controls
  proven; no intelligence claim licensed).
- Wherever P7 is referenced, this is the standing statement: the elaborate
  benchmark harness is evidence of honest measurement machinery, NOT evidence
  of reasoning. A real-provider holdout run (env-gated `RUN_REAL_E2E`, owner
  run) is the prerequisite for any benchmark-based claim.

## What shipped (committed artifacts)

| Artifact | Where | Status |
|---|---|---|
| Frozen protocol | `docs/benchmark/BENCHMARK_PROTOCOL.json` | committed, SHA-pinned (`test/benchmark_protocol_test.rb`) |
| Pilot harness | `script/benchmark_run` | fixture-only (label permanently `pilot`; verdict can never claim go) |
| Holdout generator | `script/benchmark_holdout` | opaque ids, temporal cutoffs, leak scan |
| Metrics/baselines/comparison | `gems/tamoz-evals/lib/tamoz/evals/benchmark/` | pure, deterministic, tested |
| 14 adversarial controls | `test/benchmark_controls_test.rb` | all pass as fixture tests |
| Go batch comparator | agentic-stream `internal/executor/native/batch.go` | tested (intention-to-treat) |

## Not done (stated, not hidden)

- Real-provider holdout execution and the go rule — owner-run, env-gated.
