# 03 — Implementation plan

Phased, buildable, and mapped to real `tamoz-evals` seams. Each phase names the
seam it extends, the durable fields it adds, the plumbing test plus the
real-provider proof, and the committed evidence with the command that produced
it. This mirrors the change protocol in `../implementation-plan/README.md`.

Sequencing rule: fixtures and oracles first (B0), then a real executor (B1),
then breadth (B2–B3), then the trend (B4), then the claim (B5). Do not build a
comparison track before the missions score deterministically on fixtures.

## Prerequisites (external — gather before B1)

- A real provider credential and the UTF-8 locale for real runs (see the
  local-run note). Real missions use DeepSeek by default; the provider identity
  is recorded, never assumed.
- A committed **capability manifest** describing the exact tools each mission is
  permitted (the input to `--capabilities`).
- A **comparison-target adapter** for Track A. The minimum is the
  `go_native_executor` baseline — preregistered in `BENCHMARK_PROTOCOL.json`
  and injected into `report.rb` as baseline cells (the non-LLM baseline library
  in `baselines.rb` is a separate thing). A real OpenClaw adapter is required
  only for the *comparative* claim (see the claim tiers in
  [02](02-mission-catalog-and-scoring.md#verdict-rule-reuse-reportrb)); without
  it, Track A supports the floor claim and absolute capability reporting. If
  added, it must run under the same matched manifest.

## Phase B0 — Fixture completeness and deterministic oracles

Goal: all nine missions run through `OpenclawMissionRunner` as a `fixture` run
and score deterministically. No provider, no claim.

- **Seam:** `openclaw_mission_runner.rb` (injected executor), the existing smoke
  cases in `gems/tamoz-evals/suites/agent/smoke/` (mcp, websearch, memory,
  schedule cases already exist and are reused as mission fixtures).
- **Build:** a fixture executor per mission that drives the real durable Session
  with a scripted model (as the smoke corpus does) and a controller-owned
  deterministic oracle that computes the metric set in
  [02](02-mission-catalog-and-scoring.md#metric-definitions) from the session
  record + effect journal — never from model self-report. This includes the
  `run_kind = fixture` path through the runner and CLI: today
  `script/benchmark_openclaw_run` hardcodes `real_provider`, so the evidence
  command below does not exist until B0 adds it.
- **Durable fields:** none new; reuse observation/receipt/lifecycle records.
- **Test (plumbing):** extend `test/openclaw_mission_runner_test.rb` so a
  fixture run produces a scored artifact + `manifest.json` for every mission,
  with `readiness.rb` reporting `fixture_or_fake_provider` (non-publishable).
- **Evidence:** `fixtures/<date>/` artifact tree + manifest; command
  `script/benchmark_openclaw_run --provider fixture --model fixture … ` (no
  `--publish`).
- **Exit bar:** nine missions scored on fixtures; readiness correctly refuses
  publication; the smoke scorecard is unchanged.

## Phase B1 — Real-provider executor (the crux)

Goal: one mission (`adaptive-read-only`) completes against a real model through
the durable CLI, with two independent witnesses.

- **Seam:** `openclaw_durable_cli_adapter.rb` — it already submits a mission
  through the durable CLI queue, drains it with the worker, reads receipts
  without advancing the session, and pulls `tamoz trace --json`. Wire it as the
  runner's executor for `run_kind = real_provider`.
- **Build:** a real-provider executor that binds the operator-supplied runtime
  (`--runtime-dir`), provider, and model; runs the mission; and returns the
  provider receipts + independent trace the runner records.
- **Durable fields:** none new; the model-effect receipts and observability
  journal already exist. Bind the mission's canonical digest to the trace digest.
- **Test (plumbing):** a fixture-mode test of the adapter (already present in
  `test/openclaw_durable_cli_adapter_test.rb`) plus a guarded real-provider
  smoke that is skipped without a credential.
- **Real-provider proof:** `readiness.rb#publishable?` returns true for the
  `adaptive-read-only` mission — provider receipt set present, trace digest bound,
  independent journal trace with model spans present.
- **Evidence:** `real-provider/<date>-<git-sha>/` for the one mission; command
  `script/benchmark_openclaw_run --runtime-dir … --provider deepseek --model
  deepseek-chat --capabilities … --artifact-root real-provider/<date>-<sha>`.
- **Exit bar:** one real mission is `publishable?`; a fabricated or missing
  witness is a typed block, never a pass.

## Phase B2 — Both surfaces and parity

Goal: every mission runs on durable CLI **and** Telegram with a measured parity.

- **Seam:** the existing durable CLI adapter for `cli`; the channel/comms path
  for `telegram`. `readiness.rb#MISSION_SURFACES = [cli, telegram]` already
  requires both.
- **Build:** a Telegram surface executor (or a durable parity harness that
  replays the same turn through the channel gateway) that records a
  `surface_executions` entry per surface; compute the `parity` metric from the
  two terminal outcomes. Parity runs go through a gateway fake at the Telegram
  API boundary (recorded requests, no real egress) — a benchmark run never
  depends on, or posts to, live Telegram.
- **Test (plumbing):** extend the runner test so each mission emits two surface
  executions and a parity score; fixture-level Telegram/CLI identity assertions
  already exist in the Phase 3 evidence coverage — reuse them.
- **Real-provider proof:** one mission completes on both surfaces with
  `parity = 1.0` under a real model.
- **Exit bar:** no mission is single-surface; parity is scored, not assumed.

## Phase B3 — Track A common-subset comparison

Goal: a matched comparison that isolates agent-loop quality.

- **Seam:** `report.rb`, `comparison.rb`, `baselines.rb` (verdict + baselines
  already implemented). Add only the comparison **executor**.
- **Build:** run each mission under the matched permission manifest for (a)
  Tamoz and (b) the comparison target (minimum: `go_native_executor` baseline;
  optional: a real OpenClaw adapter). Feed both into `Report.build` with
  `controls_passed` gated by the preregistered controls.
- **Durable fields:** none new; cells are the existing report cells.
- **Test (plumbing):** a fixture matched run yields a deterministic verdict; the
  existing `benchmark_harness_test`/`benchmark_report_test` patterns extend to
  the mission cells.
- **Real-provider proof:** a matched `real_provider` run produces a per-axis
  `go`, `negative`, or `inconclusive` verdict against the strongest baseline,
  with confidence intervals.
- **Exit bar:** a verdict exists for at least the `adaptive_continuation` and
  `governance` axes, labeled by claim tier — with only `go_native_executor` the
  label is *floor*; the *comparative* label additionally requires the OpenClaw
  adapter. Track B breadth is reported separately, never folded into the
  verdict.

## Phase B4 — Longitudinal scoreboard and regression gate

Goal: improvement and regression are visible over time.

- **Seam:** new committed artifact
  `documentation/benchmark/scoreboard/INTELLIGENCE_SCOREBOARD.json`, regenerated
  by its own command (never hand-edited), following the same freeze discipline
  as the protocol/holdout pins.
- **Build:** an append step in the run flow that writes one scoreboard entry
  (shape in [02](02-mission-catalog-and-scoring.md#longitudinal-scoreboard)) for
  an accepted `real_provider` run; a regression test that fails when the newest
  run drops an axis below the prior accepted run's interval (read from the
  referenced artifact) without a reviewed note.
- **Test (plumbing):** the append is deterministic and idempotent; the
  regression gate fires on a synthetic regression fixture.
- **Evidence:** the committed scoreboard file plus the manifests it references.
- **Exit bar:** every accepted run leaves a dated, build-bound entry; a silent
  regression is impossible.

## Phase B5 — Full run and bounded claim

Goal: the first honest intelligence statement.

- **Build:** run all nine missions, both surfaces, both tracks, under a real
  provider with controls passed.
- **Real-provider proof:** all missions `ready`; readiness `publishable?`; no
  hard-zero; a committed report and scoreboard entry.
- **Exit bar / claim rule:** the published claim is limited to what the matched
  data supports — per axis, per claim tier (floor vs comparative) — with
  capability-availability differences reported alongside completion rates. A
  missing family is an *unavailable result* that blocks the claim for that axis
  — it never lowers the bar.

## Build/reuse ledger (do not reinvent)

| Need | Reuse | Build |
| --- | --- | --- |
| Run missions, write artifacts | `OpenclawMissionRunner` | mission fixtures + oracles (B0) |
| Real durable execution | `OpenclawDurableCliAdapter`, durable Session, worker | real-provider executor binding (B1) |
| Publication gate | `Readiness` | — |
| Scoring / verdict | `Report`, `Comparison`, `Metrics`, `Baselines` | comparison executor (B3) |
| Holdout / anti-leak | `benchmark_holdout`, `leak_scan.rb` | bind mission cases to the holdout (B0) |
| Fast regression | `AgentSmokeScorecard` | — (kept as-is) |
| Trend over time | — | scoreboard + regression gate (B4) |

## Definition of done (whole program)

A single command produces a committed, reviewable report and one scoreboard
entry, both bound to an exact build and a real provider, with a per-axis verdict
and honest availability annotations — and every gate between fixture plumbing
and a real intelligence claim is enforced by code, not prose.
