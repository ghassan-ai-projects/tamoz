# Eval improvement — measuring the agent, not just its coding slice

Date: 2026-09-17

Tamoz's agent is a durable, approval-governed operator: sessions that survive `kill -9`,
reviewed change plans, capability sources (tools/skills/MCP/websearch), memory, healing,
improvement, scheduling, and Telegram. The evaluation of it is spread across four surfaces,
and only one of them is real-model and cadenced today. This folder plans and tracks all of
them.

- [`RESEARCH.md`](RESEARCH.md) — the four surfaces, the agent's declared capability surface,
  the verified framework defects, and what frontier labs actually evaluate.
- [`QUALITY_BAR.md`](QUALITY_BAR.md) — what "useful" means, as pass/fail criteria.
- [`PLAN.md`](PLAN.md) — the work: cadence (W), framework correctness (F), capability breadth (C).

## The four surfaces

| Surface | Measures | Real model? |
|---|---|---|
| [`agenteval/`](../../agenteval/) maintenance pack | Generated repo-maintenance work (comprehend, repair, diagnose, implement, author tests, docs) × adversity | Yes — the only live real-model suite |
| `gems/tamoz-evals` benchmark (`script/benchmark_openclaw_run`) | 9 missions × 8 canonical axes + 9 chat scenarios, CLI↔Telegram parity, per-axis verdict with holdout and publish gate | Harness built; command **fails closed** until the plan's phases land |
| `test/autonomy_scorecard_test.rb` (`AgentSmokeScorecard`) | Machinery: unattended completion, schedules, crash recovery, approvals, unknown effects, channels, isolation | Scripted (a plumbing gate, never an intelligence claim) |
| `tamoz-evals` artifact verification | Whether the evidence itself is well-formed | n/a |

**Current honest status:** one slice is measured, and that slice is currently measuring a
plan-approval loop rather than coding — 28 of 28 failures in the 2026-09-17 run are the
plan-review gate, and only 2 of 46 trials wrote a file (RESEARCH §4.1). No coding score from
that run should be quoted.

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

Known gaps in this cadence, planned as W1/F1–F5: the Rakefile is not yet interpreter-safe,
there is no `baseline` promotion, and `compare` reads the two newest local reports rather than
the committed baseline.

`agenteval/` is git-ignored (a local tool tree), so **committed baselines and findings live
here**, under `docs/eval-improvement/`, not under `agenteval/reports/`. The 2026-09-17 record
is [`baseline-20260917.json`](baseline-20260917.json) with
[`FINDINGS-20260917.md`](FINDINGS-20260917.md) — read the correction at the top of the
findings: that run measures the plan gate, not coding.

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
