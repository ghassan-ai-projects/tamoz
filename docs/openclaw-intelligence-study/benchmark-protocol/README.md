# Intelligence benchmark — protocol design and plan

Status: protocol plus operator runbook. The canonical runner and durable
adapter exist; scenario-specific fixture/oracle execution and Telegram parity
remain explicitly incomplete.

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

## Run the real benchmark

The runner executes the missions in the catalog supplied by `--missions` (the
default is the canonical nine-mission catalog). It does not infer a scenario
from a Markdown file, and `SCENARIO_INDEX.json` is currently documentation
metadata rather than a runner input.

Prerequisites:

- a configured Tamoz runtime containing `config.yaml`;
- a workspace path the runtime is allowed to inspect;
- a capability manifest whose states are observed, not guessed; and
- an ignored `.env` file containing `OPENROUTER_API_KEY`.

The runner reads only the selected provider's credential and API-base entries
from `.env`; it never prints them or writes them to an artifact. Shell
environment variables take precedence. Use `--env-file PATH` or
`TAMOZ_ENV_FILE` to select another env file.

The capability manifest uses the readiness seven-tuple:

```json
{
  "local:read_file": {
    "exists": true,
    "reachable": true,
    "authorized": true,
    "attempted": true,
    "effective": true,
    "completed": true,
    "verified": true
  }
}
```

Set each value from real control-plane evidence. Do not copy this example into
an intelligence run unless every field is true for that run.

Run the canonical catalog through the real provider:

```bash
artifact_base="$PWD/benchmark-artifacts"
artifact_root="real-provider/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD)"

script/benchmark_openclaw_run \
  --runtime-dir "$HOME/.tamoz" \
  --workspace "$PWD" \
  --provider openrouter \
  --model deepseek/deepseek-chat \
  --capabilities /path/to/capabilities.json \
  --artifact-base "$artifact_base" \
  --artifact-root "$artifact_root"
```

The command prints the readiness result and exits non-zero when evidence is
blocked. It writes the manifest at
`<artifact-base>/<artifact-root>/manifest.json` and per-mission artifacts beside
it. A real run is not publishable merely because the model responded: provider
effect receipts, an independent trace, controls, artifact verification, and
both required surfaces must pass.

Re-check an existing manifest without advancing the runtime:

```bash
script/benchmark_openclaw_readiness \
  --protocol documentation/benchmark/BENCHMARK_PROTOCOL.json \
  --manifest "$artifact_base/$artifact_root/manifest.json" \
  --missions documentation/benchmark/OPENCLAW_MISSIONS.json \
  --artifact-base "$artifact_base"
```

Add `--publish` only when the operator intends to enforce the publication gate.
Do not place fixture or scripted-model output under `real-provider/`; fixture
results are plumbing evidence and never intelligence evidence.

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

## The one command (full publishable target)

```bash
script/benchmark_openclaw_run \
  --runtime-dir <configured runtime> \
  --provider openrouter --model deepseek/deepseek-chat \
  --capabilities <capability-manifest.json> \
  --artifact-root real-provider/<date>-<git-sha> \
  --controls-passed --publish
```

For the current real-intelligence run, keep `OPENROUTER_API_KEY` in the ignored
`.env` file and use the OpenRouter provider/model pair shown above. RubyLLM
supplies the default `https://openrouter.ai/api/v1` base; an empty or missing
key is an external blocker. The `--controls-passed --publish` form is the full
target command, not a bypass for missing receipts, parity, or scenario oracles.

Until the plan's phases land, this command fails closed with a typed reason,
which is the correct behavior — it never emits a fabricated verdict.
