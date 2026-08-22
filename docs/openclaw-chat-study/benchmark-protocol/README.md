# Communication benchmark — protocol design and plan

Status: protocol and plan. No *comms-specific* benchmark runner exists yet, but
most of what it needs already does: the production `tamoz-comms` / `tamoz-telegram`
gems, a scripted fake transport, a fault-injecting durable-session runtime, and
the intelligence benchmark's runner/adapter/readiness seams. B0 extends those; it
does not stand up a parallel harness.

This folder is the executable design for the benchmark that answers one question
honestly: **is the Tamoz chat experience trustworthy and responsive, and is it
improving over time?** It exists because the study proved the *design* but never
the *experience* — every composition test to date runs a deterministic provider
and a fake transport, so it measures machinery, not what a correspondent feels.

These documents turn the study's required composition tests
(`../06-scenario-matrix.md`) and the implementation plan's Phase 3 exit bar into
something buildable: a measurement model, a scenario catalog with scoring, and a
phased plan that extends the existing comms/eval seams rather than standing up a
parallel benchmark stack.

## Read in this order

1. [01-protocol-design.md](01-protocol-design.md) — what "trustworthy
   communication" means here, the eight canonical axes, the two tracks, the
   task/delivery state-axis model, evidence and provenance rules, statistical
   validity, and the anti-gaming threat model.
2. [02-scenario-catalog-and-scoring.md](02-scenario-catalog-and-scoring.md) — the
   nine canonical scenarios, per-scenario acceptance, metric definitions, the
   per-axis verdict rule, and the longitudinal scoreboard.
3. [03-implementation-plan.md](03-implementation-plan.md) — phased work items,
   each mapped to a concrete comms/agent seam, with exit bars and the committed
   evidence each phase must produce.
4. [scenarios/](scenarios/README.md) — the agent-drivable ladder (C1–C9),
   frontier specifications (F1–F3), and the machine-readable scenario contract an
   external driver follows to set up, run, and verify each scenario.

## What already exists (the seams the plan builds on)

| Seam | File | Role |
| --- | --- | --- |
| Production comms | `gems/tamoz-comms/lib/tamoz/comms/*` | Admission, commands, comms store, delivery, delivery sink, rendering, transport interface, approval/evidence. |
| Production Telegram | `gems/tamoz-telegram/lib/tamoz/telegram/*` | Normalizer, transport, client. |
| Durable execution + delivery | `Agent::Worker`, `Agent::DeliveryDrainer`, `Agent::OutboxDeliverySink`, `Sqlite::CommsOutbox`, `Sqlite::CommsStore` | The real Gateway/Worker/Drainer/outbox path a scenario drives. |
| Fake transport | `Tamoz::Comms::Transport` interface + `ScriptedTransport` in `test/comms_gateway_test.rb` | Records requests, no egress — the Track A transport. |
| Fault-injecting runtime | `gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb` | Lease/request/claim/recover/checkpoint fault actions on real SQLite. |
| Mission runner | `gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb` | Runs a catalog entry; writes atomic, bounded artifacts + `manifest.json`. |
| Durable CLI adapter | `.../benchmark/openclaw_durable_cli_adapter.rb` | Submits through the durable CLI queue, drains with the worker, reads receipts without advancing, pulls an independent trace. |
| Readiness / verdict | `.../benchmark/readiness.rb`, `report.rb`, `comparison.rb` | Distinguishes fixture from real; blocks publication without receipts + trace; derives the verdict. |

What B0–B3 add on top: comms-specific scenario oracles, a Telegram surface
executor/parity harness (the durable CLI adapter records Telegram as unavailable
today), and the comms scoring adapter. See
[03-implementation-plan.md](03-implementation-plan.md).

## First principles (inherited, non-negotiable)

- **Measurement replaces perception.** No "responsive" or "trustworthy" claim
  exists until a real run reports it. A fake-transport composition result is never
  an experience claim — it is a plumbing regression gate.
- **Real runs use a real provider and a real transport.** Experience scenarios run
  against a real model (DeepSeek by default) over a real send boundary. The
  provider and transport class are recorded in every artifact, and readiness
  refuses to publish a `fixture` run.
- **Task truth and delivery truth are separate axes.** `completed +
  delivery=unknown` is never averaged into a success or a failure.
- **Fail closed.** A blocked oracle, an ambiguous send reported as terminal, a
  fabricated milestone, a witness divergence, or a fixture published as real is a
  failure of that run, never averaged away.
- **Reuse, don't rebuild.** Extend the comms/eval seams above. Do not add a new
  runtime, event bus, delivery worker, or in-memory status cache to satisfy a work
  item.

## Two roles — do not conflate them

- **Subject** — the Tamoz communication path under a real provider and transport.
  It *handles the turn*. It is the thing being measured. It never scores itself.
- **Driver** — the external agent (OpenClaw, or any driver) following the runbook.
  It *prepares the fixture, submits the turn through a surface, and verifies the
  artifacts* against the assertions. The driver never handles the turn and its own
  cleverness is never part of the score.

A scenario is PASS/FAIL about the **subject**, established by the **driver**
reading deterministic, controller-owned evidence — never either agent's
self-report.

## The gate discipline (until the harness lands)

Until B0 builds the comms scenario oracles and binds them into the runner, there
is no fixture command to copy and no artifact to publish. A scenario driver must
not relabel an ordinary comms test run as scenario evidence. The real-run
entrypoint fails closed with a typed reason until the plan's phases land — which is
the correct behavior; it never emits a fabricated verdict.
