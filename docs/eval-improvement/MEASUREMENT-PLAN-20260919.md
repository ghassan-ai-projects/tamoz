# Measurement plan — turn every "unknown" into a measured number

Per-capability recipes: [`measurement-plans/`](measurement-plans/README.md) (one file per
capability). This file is the phased, spend-aware sequencing over them.


The instruments are trustworthy (graders proven to discriminate, independent, honest). What is
missing is **evidence**: every graded eval still runs a scripted/fixture model, so real capability
quality is unmeasured. This plan runs the ready instruments against the **real model** (DeepSeek,
per [[real-llm-not-fake]] and the local-run notes), with statistical rigor, so each capability
gets a number with an interval instead of "unknown".

Rule: real runs use the real provider; nothing is published without its provenance and its 95%
interval; a low number read against instruments proven to discriminate is a real weakness, not an
artifact. Anything that needs tamoz production changes or spend is marked — those are the owner's
gates, not silent steps.

## Phase 0 — unblock and smoke (cheap; do first)

0.1 **Provider path smoke.** One real-DeepSeek trial through each harness (coding, missions, chat,
    thermal tournament) to prove the real path runs end to end (key + UTF-8 locale). No scoring
    claim — just "it runs."
0.2 **Resolve the coding plan-gate blocker (PRODUCT DECISION).** The one real-ish signal to date:
    the plan-review gate aborted 28/46 coding trials before any edit. A live coding run is
    worthless if the agent cannot act. Diagnose config-vs-product from the landed stage/transcript,
    then either reconfigure the gate or accept it as the finding. **Owner call — may touch tamoz.**
0.3 **Statistics defaults.** Set the live runs to `repeat>=2, seeds>=4`; wire cost/stage into the
    breadth report as it already is in coding.

## Phase 1 — measure the ready capabilities (real model, needs spend)

Each: real DeepSeek, `seeds>=4, repeat>=2`, `pass^k` over scenarios + Wilson interval, split by
composition, against controls that already pass.

| # | Capability | How | Turns "unknown" → |
|---|---|---|---|
| 1.1 | **Coding** | `AGENTEVAL_SEEDS=4 AGENTEVAL_REPEAT=2 rake agenteval:run` then `:compare`, `:baseline` | real solve-rate + interval + stage/cost (after 0.2) |
| 1.2 | **Noise floor (S3)** | run 1.1 twice, same config, different time | the delta below which no improvement is claimed |
| 1.3 | **Intelligence missions** | `script/benchmark_openclaw_run --provider deepseek --model … --controls-passed --publish` (controls earned by `rake benchmark:prove`) → writes `INTELLIGENCE_SCOREBOARD.json` | governance / recovery / self-knowledge / external-tool-use / memory / parity — the "agent" axes |
| 1.4 | **Chat** | real-provider run of the 9 comms scenarios through the same harness | chat competence per scenario |
| 1.5 | **Decision (physical brain)** | thermal shadow tournament (WP-T3) with real DeepSeek — no hardware | real supervisory judgment vs baseline, paired interval |

## Phase 2 — the distinctive claims (build a real-model variant, then run)

| # | Capability | Build (offline) + Run (real) | Turns "unknown" → |
|---|---|---|---|
| 2.1 | **Self-healing** | inject real failures; run the healing loop with a real model; measure recovery rate AND that bounded/reviewed/no-blind-retry hold under a real model (not just fixtures) | does it actually fix real failures, and stay safe doing so |
| 2.2 | **Self-improvement** | generate candidates from real trajectories; evaluate on a **distinct holdout**; measure whether promoted heuristics actually improve the agent, with rollback measured (ADR-023, C7) | does self-improvement actually make it better |
| 2.3 | **Autonomy** | real-model variants of the model-dependent scorecard cases (unattended completion, approval correctness, recovery, capability honesty) — keep separate from the scripted plumbing gate | real autonomous competence |

## Phase 3 — physical actuation + horizon (design decision / hardware)

- 3.1 **Evidence-fitness gap (O1, DESIGN DECISION).** Decide: add a recommendation-time evidence
  gate (defence in depth) so the brain won't propose actuation on unfit evidence, or accept the
  gap. Either flips the pending-gap eval to a real pass or documents acceptance. **Owner call.**
- 3.2 **Dispatch-side physical safety / actuation claim (P3).** The bench run tests the *dispatcher*
  (Go), not the brain — needs hardware and the arduino-bench manifest (p0–p8). Only this, and the
  8-hour soak (P8, the long-horizon axis), genuinely need hardware.

## What each phase costs

- Phase 0: ~free (a handful of real calls) + one product decision (0.2).
- Phase 1: real API spend + hours (coding is ~184 trials at seeds=4/repeat=2; missions/chat are
  smaller). This is the highest-value spend — it removes most "unknown"s at once.
- Phase 2: build effort + more spend; the distinctive claims.
- Phase 3: a design decision (3.1) and hardware (3.2).

## Definition of done — no "unknown" remains

Every capability in the rating table carries a **real-provider number with a 95% interval**, run
against a discriminating instrument, with a measured noise floor beside it and its provenance
(model/provider/digest) recorded — or an explicit, recorded refusal where a claim cannot yet be
earned (e.g. the actuation claim until the bench exists). The `INTELLIGENCE_SCOREBOARD.json` is
non-empty and the coding baseline reflects an agent that actually acts.

Prereqs already met: instruments discriminate; evals independent; controls green; stats machinery
(`pass^k`, Wilson, McNemar) in place. The gate now is spend + the two owner decisions (0.2, 3.1).
