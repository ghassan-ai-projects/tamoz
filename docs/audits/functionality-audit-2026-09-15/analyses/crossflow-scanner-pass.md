# Standalone cross-flow scanner pass

Date: 2026-09-15  
Checkout: `audit-15-09`, code baseline `582ae55`  
Mode: read-only boundary inventory and static signal scan. This file is a
scanner record only; it is not an analyst verdict, a challenge, or closure.

## Method and evidence

The scan started from the 13 cross-flow rows in `COVERAGE.md`, then followed
the named entry seams into the live source tree. It used `rg --files` for the
path inventory and `rg -n` for boundary verbs and state names (`require`,
`enqueue`, `claim`, `checkpoint`, `effect`, `approval`, `admit`, `deliver`,
`memory`, `promote`, `record`, `export`, and `verify`). The scan included Ruby
sources, gemspecs, executable shims, and the tests whose names explicitly
encode the flow. A match is a routing signal; it was not promoted to a finding
without a source trace in the analyst lane.

Observed repository inventory:

| Inventory | Result |
|---|---:|
| Cross-flow rows | 13 (CF01–CF13) |
| Gem library directories | 27 |
| Installed gem executables | 3 |
| Repository `bin/` launchers | 6 |
| `script/` support files | 45 |
| `scripts/` support files | 1 |
| Root `Rakefile` | present |

The existing component scan found these cross-flow-relevant signals in the
same checkout: 19 `model.generate` files, 2 `Open3.capture*` files, 6
`Net::HTTP` files, 13 `Thread.new` files, 2 `Queue.new` files, and 10
`sleep(` files. The flow mapping below records where each signal enters a
boundary; it does not infer reachability from the count alone.

## Boundary map

| Flow | Entry and boundary owners found in source | Scanner result |
|---|---|---|
| CF01 | Gem entry files and gemspecs; `TamozGemspec.build` (`gems/gemspec_helper.rb:10-52`); `tamoz/graph` Zeitwerk setup (`gems/tamoz-graph/lib/tamoz/graph.rb:3-22`); packaging and dependency tests | complete inventory and signal pass |
| CF02 | Session start/resume (`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:316-368`); graph durable runner (`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:56-160`); checkpoint writer (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_writer.rb:69-154`); cancellation token (`gems/tamoz-cancellation/lib/tamoz/cancellation_token.rb:31-113`) | complete inventory and signal pass |
| CF03 | Session plan/execute (`gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:20-304`); capability binding (`gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:150-176`); approval engine (`gems/tamoz-approval/lib/tamoz/approval/engine.rb:31-126`); observability recorder (`gems/tamoz-observability/lib/tamoz/observability/recorder.rb:1-128`) | complete inventory and signal pass |
| CF04 | Runtime effect entry (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:33-173`); effect preparation/completion (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:139-216`, `effect_completion.rb:79-167`); session unknown handling (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_attempt.rb:240-263`) | complete inventory and signal pass |
| CF05 | Profile authority (`gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:176-303`); capability admission (`gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:161-169`); MCP source (`gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:250-287`); session exposure (`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:337-352`) | complete inventory and signal pass |
| CF06 | CLI durable dispatch (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:579-635`); worker routing (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:196-335`); request claim (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:20-276`); graph runner (`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:56-160`) | complete inventory and signal pass |
| CF07 | Schedule values/contract (`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:5-75`); SQLite materialization (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:300-559`); worker settlement (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:350-406`, `:560-587`) | complete inventory and signal pass |
| CF08 | Telegram transport (`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:1-98`); Comms admission/rendering (`gems/tamoz-comms/lib/tamoz/comms/admission.rb:1-130`, `rendering.rb:1-104`); gateway pass (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:189-267`); outbox/drainer (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:73-205`, `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:45-151`) | complete inventory and signal pass |
| CF09 | Episode request (`gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:438-590`); evidence reverse channel (`gems/tamoz-stream/lib/tamoz/stream/evidence_client.rb:63-174`); live learning (`gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:1-223`); memory/session construction (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:897-919`) | complete inventory and signal pass |
| CF10 | Memory admission/retrieval (`gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb:1-478`, `retrieval.rb:1-206`); lifecycle/consolidation (`lifecycle.rb:1-253`, `consolidation.rb:1-326`); SQLite memory store (`gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb:1-723`); session memory bridge (`gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb:1-129`) | complete inventory and signal pass |
| CF11 | Failure/remediation entry (`gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation.rb:46-114`, `remediation/session.rb:14-290`); candidate lifecycle (`gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/candidate_lifecycle.rb:24-271`); promotion/rollback (`promotion.rb:38-160`); session repair (`gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:1-129`) | complete inventory and signal pass |
| CF12 | Signal construction (`gems/tamoz-observability/lib/tamoz/observability/signal.rb:13-225`); recorder/drain (`gems/tamoz-observability/lib/tamoz/observability/recorder.rb:1-128`, `gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:9-113`); OTLP HTTP (`gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:12-170`); gateway/runtime producers | complete inventory and signal pass |
| CF13 | Artifact verification (`gems/tamoz-evals/lib/tamoz/evals/verifier.rb:8-580`); eval CLI (`gems/tamoz-evals/lib/tamoz/evals/cli.rb:31-93`); runner umbrella (`gems/tamoz-evals-runner/lib/tamoz/evals/runner.rb:3-47`); runtime entry points and release scripts | complete inventory and signal pass |

## What this does and does not prove

All 13 cross-flow rows now have a standalone scanner record, a source map, and
a boundary owner candidate. The scan does not prove that every transition is
correct, that a caller is reachable in a packaged install, or that a test
exercises the failure path. Those claims require the analyst report, an
independent challenge for every critical/major finding, and coordinator
synthesis under `BAR.md`.

The earlier logs `/tmp/tamoz-agents/scan_durable_session.log` and
`/tmp/tamoz-agents/scan_authority_tools.log` remain partial historical leads;
this report is the current complete scanner inventory. No production code,
tests, configuration, generated artifact, or unrelated documentation changed.
