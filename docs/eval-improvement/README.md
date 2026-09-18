# Eval improvement — measuring the agent, not just its coding slice

Date: 2026-09-17

Tamoz's agent is a durable, approval-governed operator that makes sense of the physical world:
sessions that survive `kill -9`, reviewed change plans, capability sources
(tools/skills/MCP/websearch), memory, healing, improvement, scheduling, Telegram — and a
sensor → decision → actuator loop it supervises without ever owning the serial port. The
evaluation of it is spread across five surfaces, and only one is a cadenced real-model suite
today. This folder plans and tracks all of them.

- [`RESEARCH.md`](RESEARCH.md) — the five surfaces, the agent's declared capability surface,
  fourteen verified framework defects, the control suite the framework is missing, the statistics
  the corpus can actually support, and what frontier labs evaluate.
- [`QUALITY_BAR.md`](QUALITY_BAR.md) — what "useful" means, as 13 pass/fail criteria.
- [`PLAN.md`](PLAN.md) — the work: cadence (W), framework correctness (F), **validity (V)**,
  **statistics (S)**, capability breadth (C), the physical loop (P).
- [`repro/verify_defects.rb`](repro/verify_defects.rb) — reproduces six of the defects offline,
  deterministically, for free. Run it before believing the research.

## The five surfaces

| Surface | Measures | Real model? |
|---|---|---|
| [`agenteval/`](../../agenteval/) maintenance pack | Generated repo-maintenance work (comprehend, repair, diagnose, implement, author tests, docs) × adversity | Yes — the only cadenced real-model suite |
| Physical / supervisory loop (`thermal-lab`) | Sensor quality + actuator capability → a bounded, risk-governed decision; typed intent, never a model effect | One real-model thermal run; verdict `inconclusive`; physical HIL open |
| `gems/tamoz-evals` benchmark (`script/benchmark_openclaw_run`) | 9 missions × 8 canonical axes + 9 chat scenarios, CLI↔Telegram parity, per-axis verdict with holdout and publish gate | Harness built; command **fails closed** until the plan's phases land |
| `test/autonomy_scorecard_test.rb` (`AgentSmokeScorecard`) | Machinery: unattended completion, schedules, crash recovery, approvals, unknown effects, channels, isolation | Scripted (a plumbing gate, never an intelligence claim) |
| `tamoz-evals` artifact verification | Whether the evidence itself is well-formed | n/a |

**Current honest status**, in three sentences that each cost something to admit:

1. One slice is measured, and that slice is currently measuring a plan-approval loop rather than
   coding — 28 of 28 failures in the 2026-09-17 run are the plan-review gate, and of the 30
   trials that had to change code, 2 did (RESEARCH §4.1).
2. The graders have not been shown to distinguish capability from inaction: a do-nothing agent
   scores 10/10 on the inaction cells, an agent that prints a directory listing scores 6/6 on the
   task family that reads strongest, and the injection gate cannot fire on the cells where
   injection is the risk (RESEARCH §7, repros D10/D12/D14).
3. The corpus is one instance wide (`seeds: [1]`) and has no measured noise floor, so at
   23 scenarios the interval is ±18.5 pp and the August→September change — "fixed 2,
   regressed 3" — is statistically indistinguishable from no change at all
   (exact McNemar, p = 1.0; RESEARCH §8).

No coding score from that run should be quoted. The right next step is not another run; it is
`PLAN.md` V1 and F7–F10, all of which are offline and free.

## Running the coding slice (cadence)

Ruby is pinned; put it on `PATH` first, or the rake tasks shell out to the system 2.6 and the
CLI fails to parse:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"

bundle exec rake agenteval:validate   # prove the corpus — deterministic, no model calls
export DEEPSEEK_API_KEY=...            # or leave it in .env; the adapter falls back to it
bundle exec rake agenteval:run         # run today's agent; writes agenteval/reports/run-<date>.json
bundle exec rake agenteval:compare     # diff the two newest reports; non-zero on a regression
```

`agenteval:run` overrides via env: `AGENTEVAL_MODIFIERS` (default `all`), `AGENTEVAL_REPEAT`
(default `2`), `AGENTEVAL_BUDGET` seconds (default `240`), `AGENTEVAL_OUT`.

Known gaps in this cadence, planned as W1/F1–F10: the Rakefile is not yet interpreter-safe,
there is no `baseline` promotion, `compare` reads the two newest local reports rather than the
committed baseline, and its `comparable` flag is unsound — the corpus digest covers the pack
selection but not the scorer, so two arbitrarily different corpora share one digest (repro D6).

Before spending money on a run, prove the defects are still there for free:

```bash
ruby docs/eval-improvement/repro/verify_defects.rb   # offline, deterministic, no API key
```

It exits 0 while a defect is open and non-zero once every one is fixed. Keep it: it changes as
each defect closes, and it caught a regression that the control suite, the validator, and the
grader tests all missed.

The harness is tracked (`agenteval/`, minus `reports/`, `sessions/` and `tmp/`), because the
thing that judges the agent has to be reviewable. **Committed baselines and findings still live
here**, under `docs/eval-improvement/`, not under `agenteval/reports/`. The 2026-09-17 record
is [`baseline-20260917.json`](baseline-20260917.json) with
[`FINDINGS-20260917.md`](FINDINGS-20260917.md) — read the corrections at the top of the
findings: that run measures the plan gate, not coding.

## Running the physical loop

The thermal supervisory loop is a tamoz-local path, deliberately kept outside the frozen
protocol until the loop is proven:

```bash
export OPENROUTER_API_KEY=... LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ruby script/thermal_real_run   # scorecard on stderr, evidence manifest JSON on stdout
```

Its fixture and scoring gates run in `ci_full`: `test/thermal_manifest_test.rb` and
`test/thermal_tournament_test.rb`. The program, its bar, and its honest status live in
[`docs/real-world-sensor-tamoz/`](../real-world-sensor-tamoz/README.md); the hardware bench,
its gateway contract, and the `arduino-bench-v1` manifest template live in the sibling
`agent-research-lab` checkout under `real-world-sensor/assessment/`. Physical claims require
that bench evidence — `physical_claims_allowed` is `false` until the HIL gates close.

## Running the breadth suites

```bash
script/benchmark_openclaw_run \
  --runtime-dir <configured runtime> \
  --provider openrouter --model deepseek/deepseek-chat \
  --capabilities <capability-manifest.json> \
  --artifact-root real-provider/<date>-<git-sha> \
  --controls-passed --publish
```

It fails closed with a typed reason until the phases in the study plans land — that is the
correct behaviour, not a bug. Contracts: the
[intelligence study](../../documentation/benchmark/openclaw-intelligence-study/README.md),
the [chat study](../../documentation/benchmark/openclaw-chat-study/README.md), and the frozen
[benchmark protocol](../../documentation/benchmark/BENCHMARK_PROTOCOL.json).

Fixture and scripted runs prove plumbing; a capability claim needs a real-provider run
recorded with its provenance.
