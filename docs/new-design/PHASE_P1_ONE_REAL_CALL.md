# P1 — One real call through the graph

Bar rules exercised: B1, B2, B3, B4, B5, B8.

## Goal

The Tamoz stream path executes one real, journaled, witnessed model call. The episode runs as a
compiled graph, not a runner script. Model events come from receipts, never from nodes.

## Why first

Everything else is noise until this is true. Today the path has never called a real model
(`P0A_SINGLE_COGNITION_OWNER.md`). P0A's Tamoz-owner decision stays provisional until this gate
passes.

## In scope

- **Fixed production episode graph.** Vertical slice only:
  `START → intake → build_frame → reason → validate → decide → END`.
  Defined in the worker composition (`bin/tamoz-stream-worker`). Compiled in process.
  No `--graph FILE` on any production route.
- **`reason` node.** Calls `EpisodeModelCall` (`gems/tamoz-agent/lib/tamoz/agent/episode_model_call.rb`)
  through `EffectDispatcher.run` (pattern: `session_effects.rb:17-29`). Effect id is the logical
  call key, not `"p1-#{episode_id}-..."` string interpolation.
- **`validate` node.** Strict `ReasoningDocument` v2 parse + grounding checks against the frame.
- **`decide` node.** Deterministic. Validated document + current allowlist → terminal decision
  state. The runner stops building decisions (`situation_request.rb:391-410` shrinks to
  translation).
- **Honest events.** The effect adapter emits `model_started/model_completed` StreamParts from the
  receipt. Nodes cannot emit model event types; the emission boundary rejects them when
  `ExecutorName=tamoz`. Unique ordinals. Real request/response digests in the proto fields.
- **`EpisodeStream` becomes a projection.** `StreamPart` → proto `EpisodeEvent`. Delete the event
  counters, the parallel budget state machine, and the terminal-result mapping
  (`episode_stream.rb:16-308` collapses to translation + wire caps). Budgets return in P2,
  computed from receipts.
- **Model authority.** Wire `model_policy` names a Profile role. Resolve via
  `ModelCall.resolve_role` (fail-closed, already landed in P0B).
- **Placement.** Node classes live in `tamoz-agent` (they need `EffectDispatcher` and
  `EpisodeModelCall`). Stream-specific services — the decision builder, the capability host, the
  wire projection — stay in `tamoz-stream` and are constructor-injected into nodes as ports at the
  worker composition. `tamoz-stream` gains no new dependency.
- **One real domain.** Aquaculture DO-crash cell from round 3, re-authored without hard-coded
  answers.
- **Local controlled endpoint.** `test/support/local_model_endpoint.rb` fronts a real, pinned local
  model server, separately controlled, logging raw request/response digests outside the worker.
  Canned or scripted responses are forbidden — that would be R3 again.

## Out of scope

- Tools, repair loop, `recall` node and memory in frame (P5), intent catalog (P4),
  reconsideration (P6), witness gateway (P3).
- Live streaming. Buffered stream stays (accepted honestly; see main plan §3.3).
- Multiple providers.
- Interim exposure, accepted: P1 runs with wire caps and the context deadline only. Receipt-based
  budgets arrive in P2. Safe here because the only model endpoint is test-controlled.

## Deletes / kills

- `test/fixtures/episode_diagnose.rb` as any form of production or demo path. Test-only, labeled
  `fixture`, blocked from emitting model events on a `tamoz` route. (Carried out in P1 — the file is
  gone; the fixed `Tamoz::Agent::EpisodeGraph` + `test/support/episode_composition.rb` replaced it.)
- Runner-side decision building and verification orchestration.
- `--graph` loading in production mode.

## Exit gate

All must pass:

1. One aquaculture episode runs end to end through the fixed graph with the real local endpoint.
2. Endpoint log digest == Tamoz receipt digest. Independently compared.
3. Perturb the endpoint's response → the selected diagnosis changes. Proves output dependence.
4. The same fixed graph also runs under an in-process test driver (no gRPC) with only the
   adapters swapped. Proves B6.
5. A node emitting `:model_started` is rejected. A fixture graph cannot produce a model event on
   a `tamoz` route.
6. Crash after a completed receipt: redispatch with fence+1 reuses the receipt. No second provider
   call. Crash after `dispatch_started` without a receipt: typed `unknown`, no blind retry.
7. Unknown role / missing profile / digest mismatch: typed failure before any provider call.
8. On an `ExecutorName=tamoz` route the Go native executor is never constructed (inspection +
   adversarial test). Proves B1 early.
9. `rake ci`, `rubocop`, `enola check` green. No new dependency edge (`tamoz-stream` still does
   not depend on `tamoz-agent`; the graph is composed at the worker).

## Allowed claim

**"A real LLM adapter path exists."** Nothing more. Not semantic correctness. Not intelligence.

## Reports must state

- Provider, model, endpoint, digests, attempt/fence.
- That telemetry is buffered, not live.
- That this is claim level 2 of 6.
