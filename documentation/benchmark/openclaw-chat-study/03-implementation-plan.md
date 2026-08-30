# 03 — Implementation plan

> Historical benchmark study. Provider and RubyLLM references describe the
> implementation under evaluation at the time; they are not current Tamoz
> production support.

Phased, buildable, and mapped to real comms/agent seams. Each phase names the seam
it extends, the durable facts it asserts on, the plumbing test plus the
real-provider/real-transport proof, and the committed evidence with the command
that produced it. This mirrors the change protocol in
`../../../docs/openclaw-chat-study/implementation-plan/README.md`.

Sequencing rule: composition harness and deterministic oracles first (B0), then a
real-transport executor (B1), then both surfaces and parity (B2), then the
comparison/verdict wiring (B3), then the trend (B4), then the claim (B5). Do not
build a real-transport track before the scenarios score deterministically on the
fake-transport composition.

## What already exists (reuse, don't rebuild)

The comms path is production code, not a greenfield. A comms benchmark **runner**
is what is missing; almost everything it drives already exists:

| Need | Reuse (already in the repo) |
| --- | --- |
| Fake transport (recorded requests, no egress) | `Tamoz::Comms::Transport` interface + the `ScriptedTransport` pattern in `test/comms_gateway_test.rb`. |
| Real durable turn: admit → worker drain → read receipts | `gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb` (submits through the durable CLI queue, drains with the worker, reads receipts without advancing, pulls an independent trace). |
| Fault-injecting durable-session driver | `gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb` (lease/request/claim/recover/checkpoint fault actions on real SQLite). |
| Catalog run + atomic artifacts + `manifest.json` | `gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb`. |
| Publication gate / verdict | `.../benchmark/readiness.rb`, `report.rb`, `comparison.rb`. |
| Scoreboard / baselines / metrics | `.../benchmark/scoreboard.rb`, `baselines.rb`, `metrics.rb`, `openclaw_publisher.rb`, `environment_loader.rb`. |
| Scenario driver + fault gate | `.../harness/sqlite_scenario_driver.rb`, `sqlite_scenario_fault_gate.rb`. The existing oracles in `benchmark/scenario_driver.rb` (`T3M1M2Oracle`, `T3M3M4Oracle`) are change-file scenarios, not comms — they are patterns to follow, not reuse. |
| Adapter/evidence tests | `gems/tamoz-evals` has its own suite: `openclaw_durable_cli_adapter_test.rb`, `durable_session_evidence_reader_test.rb`, `scoreboard_test.rb`, `scenario_driver_test.rb`, `comparison_executor_test.rb`. |
| Production comms/telegram seams under test | `gems/tamoz-comms` (`admission`, `commands`, `comms_store` — the contract module; the SQLite implementation is in `gems/tamoz-sqlite` — `delivery`, `delivery_sink`, `rendering`), `gems/tamoz-telegram` (`normalizer`, `transport`, `client`), `Tamoz::Agent::Worker` (gems/tamoz-agent), `Tamoz::Comms::DeliveryDrainer` (gems/tamoz-comms), `Tamoz::SQLite::CommsOutbox` (gems/tamoz-sqlite). |

What is genuinely **new**: comms-specific scenario oracles, and a Telegram surface
executor/parity harness (the durable CLI adapter currently records Telegram as
unavailable). B0 adds these on top of the seams above — it does not stand up a
parallel harness.

## Prerequisites (external — gather before B1)

- A real provider credential. Provider and model are explicit choices, not
  defaults: `script/benchmark_openclaw_run` requires `--provider`/`--model`.
  OpenRouter is a supported provider path (`OPENROUTER_API_KEY`, resolved by
  `RubyLLMModel::ENV_KEYS`); the existing live default
  (`script/live_alms_telegram`) is direct DeepSeek via `DEEPSEEK_API_KEY`, not
  DeepSeek-via-OpenRouter. Real runs also need the UTF-8 locale (see the
  local-run note in the repo memory). The provider identity is recorded, never
  assumed.
- A **real or recorded-live transport** binding for Telegram. A benchmark run uses
  a fake transport (the `ScriptedTransport` pattern) for Track A; a Track B parity
  claim needs a real send boundary (or a faithfully recorded live session), with
  the transport class recorded in every artifact.
- The Phase 1 **lifecycle vocabulary and request references** must already exist
  (`../../../docs/openclaw-chat-study/implementation-plan/02-phase-1-truthful-status-and-commands.md`); the
  benchmark scores against that closed vocabulary and cannot start before it.

## Phase B0 — Composition harness and deterministic oracles

Goal: all nine scenarios run through the composition harness as a `fixture` run
and score deterministically. No provider, no transport, no claim.

- **Seam:** extend `OpenclawMissionRunner` to drive a comms scenario, using
  `SQLiteScenarioRuntime` for the durable-session + fault injection, the
  `ScriptedTransport` pattern (against `Comms::Transport`) for the fake transport,
  a deterministic provider, and the real `Comms::Gateway` / `Agent::Worker` /
  `DeliveryDrainer` / `Agent::Session` seams. Existing tests
  (`test/comms_gateway_test.rb`, `test/comms_admission_test.rb`,
  `test/delivery_drainer_test.rb`, `test/agent_outbox_delivery_sink_test.rb`,
  `test/comms_cli_ops_test.rb`, `test/agent_session_kill_matrix_test.rb`,
  `test/sqlite_request_inbox_test.rb`, `test/tamoz_telegram_transport_test.rb`)
  are the scenario building blocks.
- **Build:** a controller-owned deterministic oracle per scenario that computes the
  metric set in
  [02](02-scenario-catalog-and-scoring.md#metric-definitions) from the durable
  request/session/effect/outbox records and the emitted milestone stream — never
  from a self-report. Bind each scenario to a stable scenario ID (`SCENARIO_INDEX.json`).
- **Durable facts:** none new; assert on the existing request, session, effect,
  and outbox rows and the `StreamPart`/outbox milestone stream.
- **Test (plumbing):** each scenario produces a scored artifact + manifest with
  `run_kind = fixture`, and `readiness.rb` refuses publication for a fixture run.
- **Evidence:** `fixtures/<date>/` artifact tree + manifest.
- **Exit bar:** nine scenarios scored deterministically on the fake transport; the
  oracle is idempotent on a fixed build; readiness correctly refuses publication.

## Phase B1 — Real-provider + real-transport executor (the crux)

Goal: one scenario (`happy-path`) completes against a real model over a real
transport, with two independent witnesses.

- **Seam:** `OpenclawDurableCliAdapter` (already submits, drains, and reads
  receipts without advancing, and pulls an independent trace) plus a real transport
  binding. Wire it as the runner's executor for `run_kind = real`.
- **Build:** a real executor that binds the operator-supplied runtime, provider,
  model, and transport; runs the scenario; and returns the durable receipts + the
  independent trace the runner records. Bind the scenario's canonical digest to the
  trace digest.
- **Durable facts:** none new; the receipts and observability trace already exist.
- **Test (plumbing):** a fixture-mode executor test plus a guarded real run that is
  skipped without a credential and a transport binding.
- **Real proof:** `readiness.rb#publishable?` returns true for `happy-path` —
  durable receipts present, trace digest bound, independent trace present, transport
  class recorded as real.
- **Evidence:** `real/<date>-<git-sha>/` for the one scenario.
- **Exit bar:** one real scenario is publishable; a fabricated or missing witness is
  a typed block, never a pass.

## Phase B2 — Both surfaces and parity

Goal: every scenario runs on durable CLI **and** Telegram with a measured parity.

- **Seam:** the durable CLI adapter for `cli`; the channel/comms path for
  `telegram`. `readiness.rb`'s two-surface requirement applies. The durable CLI
  adapter currently records Telegram as unavailable — B2 adds the missing surface
  executor.
- **Build:** a Telegram surface executor (or a durable parity harness replaying the
  same turn through the gateway) that records a surface execution per surface;
  compute `parity` from the two terminal outcomes — equality of terminal task state
  and delivery outcome, never text similarity. Track A parity runs go through the
  `ScriptedTransport` fake (recorded requests, no egress); a Track B parity claim
  needs the real send boundary.
- **Test (plumbing):** each scenario emits two surface executions and a parity
  score; reuse the cross-surface identity assertions from the Phase 3 composition
  coverage.
- **Real proof:** one scenario completes on both surfaces with `parity = 1.0` under
  a real model and transport.
- **Exit bar:** no scenario is single-surface; parity is scored, not assumed.

## Phase B3 — Verdict wiring and controls

Goal: a per-axis verdict labeled by claim tier.

- **Seam:** `report.rb` / `comparison.rb` (verdict already implemented); the
  readiness/controls gate. Add only the comms scoring adapter.
- **Build:** feed the scored cells into `Report.build` with `controls_passed` gated
  by the preregistered controls (admission-before-ack, owner-fencing,
  unknown-preservation, context-inclusion). Emit a per-axis `go` / `negative` /
  `inconclusive` verdict with the sample count.
- **Test (plumbing):** a fixture run yields a deterministic per-axis verdict labeled
  `floor` (Track A); the existing `benchmark_report_test` patterns extend to the
  comms cells.
- **Real proof:** a real run produces a per-axis verdict labeled `experience`
  (Track B) for at least the `identity`, `delivery_truth`, and `liveness` axes.
- **Exit bar:** a verdict exists per axis, labeled by claim tier; a Track A pass is
  never labeled an experience claim.

## Phase B4 — Longitudinal scoreboard and regression gate

Goal: improvement and regression are visible over time.

- **Seam:** new committed artifact
  `documentation/benchmark/scoreboard/COMMUNICATION_SCOREBOARD.json`, regenerated
  by its own command, following the freeze discipline of the intelligence
  scoreboard/protocol pins.
- **Build:** an append step that writes one scoreboard entry (shape in
  [02](02-scenario-catalog-and-scoring.md#longitudinal-scoreboard)) for an accepted
  `real` run; a regression test that fails when the newest run drops an axis below
  the prior accepted run without a reviewed note.
- **Test (plumbing):** the append is deterministic and idempotent; the regression
  gate fires on a synthetic regression fixture.
- **Evidence:** the committed scoreboard file plus the manifests it references.
- **Exit bar:** every accepted run leaves a dated, build-bound entry; a silent
  regression is impossible.

## Phase B5 — Full run and bounded claim

Goal: the first honest experience statement.

- **Build:** run all nine scenarios, both surfaces, both tracks, under a real
  provider and a real transport with controls passed.
- **Real proof:** all scenarios ready; readiness publishable; no hard-zero; a
  committed report and scoreboard entry.
- **Exit bar / claim rule:** the published claim is limited to what the real data
  supports — per axis, per claim tier (floor vs experience) — with the sample count
  stated and cost reported alongside. A scenario blocked by a missing real transport
  is an *unavailable result* that blocks the claim for its axis; it never lowers the
  bar.

## Build/reuse ledger (do not reinvent)

| Need | Reuse | Build |
| --- | --- | --- |
| Drive a composed turn, assert on durable rows | `OpenclawMissionRunner`, `SQLiteScenarioRuntime`, `ScriptedTransport` pattern | comms scenario oracles (B0) |
| Real durable execution + delivery | `OpenclawDurableCliAdapter`, durable CLI/comms path, `DeliveryDrainer`, `CommsOutbox` | real provider + transport executor binding (B1) |
| Both surfaces | durable CLI adapter, channel/comms path | Telegram surface executor + parity metric (B2) |
| Publication gate / verdict | `Readiness`, `Report`, `Comparison` | comms scoring adapter + controls binding (B3) |
| Fast regression | Track A composition tests | — (kept as-is) |
| Trend over time | — | scoreboard + regression gate (B4) |

## Definition of done (whole program)

A single command produces a committed, reviewable report and one scoreboard entry,
both bound to an exact build, a real provider, and a real transport, with a
per-axis verdict and honest availability annotations — and every gate between
fixture plumbing and a real experience claim is enforced by code, not prose.
