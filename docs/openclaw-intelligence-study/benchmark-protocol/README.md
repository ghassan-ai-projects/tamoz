# Intelligence benchmark — protocol design and plan

Status: design/plan only. No runtime code is added by these documents.

This folder is the executable design for the benchmark that answers one
question honestly: **is Tamoz measurably more capable, and is it improving
over time?** It exists because the OpenClaw study proved the *plumbing* but
never the *intelligence* — every green test to date runs a scripted model, so
it measures machinery, not judgment.

These documents turn `implementation-plan/06-phase-5-measured-intelligence.md`
into something buildable: a measurement model, a mission catalog with scoring,
and a phased plan that extends the existing `tamoz-evals` gem rather than
standing up a parallel benchmark stack.

## Read in this order

1. [01-protocol-design.md](01-protocol-design.md) — what "intelligence" means
   here, the two measurement tracks, the capability-state model, evidence and
   provenance rules, statistical validity, and the anti-gaming threat model.
2. [02-mission-catalog-and-scoring.md](02-mission-catalog-and-scoring.md) — the
   canonical missions, per-mission acceptance, metric definitions, the verdict
   rule, and the longitudinal scoreboard that tracks improvement.
3. [03-implementation-plan.md](03-implementation-plan.md) — phased work items,
   each mapped to a concrete `tamoz-evals` seam, with exit bars and the
   committed evidence each phase must produce.
4. [scenarios/](scenarios/README.md) — the agent-drivable ladder (T1–T11),
   frontier specifications (F1–F9), and the machine-readable scenario contract
   an external driver follows to set up, run, and verify each mission.

## First principles (inherited, non-negotiable)

- **Measurement replaces perception.** No "more intelligent" claim exists until
  a matched benchmark reports it. A scripted-model result is never intelligence
  evidence — it is a plumbing regression gate (inherited from
  [06-phase-5-measured-intelligence.md](../implementation-plan/06-phase-5-measured-intelligence.md)).
- **Real runs use a real provider.** Intelligence missions run against a real
  model (DeepSeek by default; see the local-run note). The provider identity is
  recorded in every artifact and the readiness gate refuses to publish a
  `fixture` run.
- **Fail closed.** A missing capability, an unknown effect outcome, a forged or
  absent witness record, or a leaked holdout truth is a failure of that run,
  never averaged away.
- **Reuse, don't rebuild.** Extend `Tamoz::Evals::Benchmark::*`, the mission runner,
  readiness, report, and the durable CLI adapter. Do not add a new runtime,
  registry, journal, or domain catalog to satisfy a work item.

## What already exists (the seams the plan builds on)

| Seam | File | Role |
| --- | --- | --- |
| Mission runner | `gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb` | Runs every catalog mission through an injected executor; writes atomic, size-bounded artifacts + `manifest.json`. |
| Durable CLI adapter | `.../benchmark/openclaw_durable_cli_adapter.rb` | Submits a mission through the real durable CLI queue, drains it with the worker, reads effect receipts, and pulls an independent trace via `tamoz trace --json`. |
| Readiness gate | `.../benchmark/readiness.rb` | Validates the control-plane evidence; distinguishes `fixture` from `real_provider`; blocks publication without provider receipts + independent trace. |
| Report / verdict | `.../benchmark/report.rb`, `comparison.rb`, `metrics.rb`, `baselines.rb` | Scores cells, binds the protocol, and derives the go/negative/inconclusive verdict from the full go-rule conjunction. |
| Scorecard (plumbing) | `.../harness/agent_smoke_scorecard.rb` | Deterministic scripted-model golden master. Stays a regression gate; never relabeled as intelligence. |
| Holdout + leak scan | `script/benchmark_holdout`, `.../benchmark/leak_scan.rb` | Preregistered, seed-deterministic holdout with truth separated from cases. |
| Frozen protocol | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | The freeze: regenerates byte-identically; any field change is a new version. |
| Mission catalog | `documentation/benchmark/OPENCLAW_MISSIONS.json` | The versioned mission set (`openclaw.missions.v1`). |
| Operator entrypoints | `script/benchmark_openclaw_run`, `script/benchmark_openclaw_readiness` | Require operator-supplied runtime/config/capabilities; exit non-zero when evidence is unavailable. |

## The one command (target end state)

```bash
script/benchmark_openclaw_run \
  --runtime-dir <configured runtime> \
  --provider openrouter --model deepseek/deepseek-chat \
  --capabilities <capability-manifest.json> \
  --artifact-root real-provider/<date>-<git-sha> \
  --controls-passed --publish
```

For the current real-intelligence run, export `OPENROUTER_API_KEY` and use the
OpenRouter provider/model pair shown above. RubyLLM supplies the default
`https://openrouter.ai/api/v1` base; an empty or missing key is an external
blocker. No fixture or scripted-model output may be placed under
`real-provider/` or described as intelligence evidence.

Until the plan's phases land, this command fails closed with a typed reason,
which is the correct behavior — it never emits a fabricated verdict.
