# Tamoz stream intelligence — the bar, the review, the plan

Status: **rev 5 — full rewrite**. Replaces rev 4. Rev 4 was 995 lines of contracts with the wrong
architecture underneath. This revision fixes the architecture first, then keeps the proof rules.

Scope: make the Tamoz stream path a real, graph-native, LLM-driven reasoner. Three test rounds
proved the mechanics (wire, supervision, approval, memory plumbing, reconsideration). This plan
builds the intelligence layer on top of them.

Each phase lives in its own file in this folder. See §5.

---

## 1. The bar — how Tamoz streams must be

Every design decision below is checked against these ten rules. Each rule has a proof. If the
implementation fails a proof, the design is not met. Do not lower the bar to pass a phase.

**B1. One thinker.**
On a stream episode, only Tamoz reasons. Agentic Stream routes, watches, and judges. No hidden
fallback to the Go native executor on a Tamoz route.
*Proof:* `ExecutorName=tamoz` never constructs the native executor. Shadow is a dispatch policy,
not a second brain.

**B2. The episode is a graph.**
The episode program is a compiled `tamoz-graph` definition — nodes, branches, reducers, limits.
The runner only validates the envelope, delivers to the durable inbox, and translates the result.
No orchestration outside nodes.
*Proof:* decision building, tool loops, repair, and reconsideration are graph nodes and branches,
not runner code. The session path (`session.rb:362-457`) is the in-repo example of doing it right.

**B3. One effect door.**
Every model call and every tool call crosses `EffectDispatcher` into the `EffectJournal`. Nothing
calls a provider or a tool raw. Replay reads receipts, never the network.
*Proof:* crash a worker mid-episode, redispatch with fence+1 — no duplicate provider call, the
journaled receipt is reused.

**B4. One event language.**
Inside Tamoz every event is a `StreamPart`. Graph nodes never emit model events. The trusted
effect adapter turns receipts into model events. Wire adapters (gRPC, stdout, outbox, SSE) only
translate.
*Proof:* a node emitting `:model_started` is rejected when `ExecutorName=tamoz`. A model event
without a completed receipt never reaches the wire.

**B5. One model authority.**
Profile `model_roles` is the only place a model is chosen. The wire carries a role name. The
worker resolves it or fails before any call.
*Proof:* unknown role, missing profile, or digest mismatch = typed failure, zero provider calls.

**B6. One in/out shape.**
Every inbound channel (gRPC episode, SSE outcome, Telegram, CLI) becomes a durable inbox request.
Every outbound byte is a projection of the same event stream. No channel logic inside the episode
graph.
*Proof:* the same episode graph runs under the gRPC worker and under a test driver with only the
adapters swapped.

**B7. No second brain.**
No planner, loop, repair, retry, or budget logic duplicated in Go, in the runner, or in a helper
class. Extend the existing seam or delete the copy.
*Proof:* one model loop runs on any serving route: the Tamoz graph. Go keeps validation, cost
control, and replay orchestration — things Tamoz must not own. The Go native executor survives
only as a frozen benchmark comparator (P7): never constructed on a serving route, never extended.

**B8. No fake intelligence.**
A fixture never emits model events in a stream run. A real run means a witnessed provider call.
Claims match evidence, never more.
*Proof:* `provider: "test"` anywhere in a stream artifact invalidates the run.

**B9. Domain is data.**
A new domain is a spec, catalogs, and skills. Zero new Ruby. Hard-coded domain tables
(`ACTION_RISKS`, `COMPENSATION_RISK`, `WITHDRAW_TYPES`, `DOWNGRADE_TYPES`, `family_for`) are
deleted, not extended.
*Proof:* a novel domain passes with the fixed graph and no Ruby diff.

**B10. Decisions are earned.**
Tamoz proposes a decision from a validated model document. Agentic Stream disposes, using its own
compiled copy of the catalogs. Confidence never unlocks authority.
*Proof:* a forged risk label, a forged catalog, and a missing catalog all fail closed — on the Go
side, without trusting Tamoz.

---

## 2. The review — what was wrong with rev 4

The owner's complaints are confirmed by the code. Short version:

**R1. The graph gem is used as a shell.** (violates B2)
- The episode "graph" is one node that does everything inline (`test/fixtures/episode_diagnose.rb:65-66`
  — removed in P1; the production path is the fixed `Tamoz::Agent::EpisodeGraph`, v4).
- The runner orchestrates around the graph: decision building, verification rows, manifest
  (`situation_request.rb:391-514`).
- Budgets, event sequencing, and terminal mapping are re-implemented in `episode_stream.rb:16-308`.
- Meanwhile the session path drives a real 8-node graph with branches and reducers. Two ways of
  driving graphs in one repo.

**R2. Logic is duplicated.** (violates B7)
- Budgets counted three ways: Go wire telemetry (`worker_executor.go:274-377`), `EpisodeStream`
  event counters, Profile budgets.
- Decision building twice: `decision_builder.rb` and the Go native executor (`native.go:366-379`).
- Model loops twice: Go native loop (`native.go:275-381`) and Tamoz `SessionDeliberation`.
- Rev 4 planned to copy the Go loop into Tamoz. That would be a third copy.

**R3. We pretended Tamoz is smart.** (violates B8)
- Rounds 1–3 "reasoning" was hard-coded Ruby literals in fixture graphs.
- Fake `provider: "test"` telemetry was emitted by the subject under test.
- The Tamoz stream path has never executed a real model call (admitted in
  `P0A_SINGLE_COGNITION_OWNER.md`).
- Any node can forge model events today (`context.rb:108-116`).

**R4. Inbound/outbound is not unified.** (violates B4, B6)
- Three event vocabularies: protobuf `EpisodeEvent`, CloudEvents, `StreamPart`.
- Two decision types: stream decision-v1 and comms `DecisionRecord`.
- Two approval pipelines: `ApprovalRelay` and comms approvals.
- Three auth models: capability token, subscriber bearer, bot token.

**R5. The agentic layer is duplicated across repos.** (violates B1, B7)
- The Go native executor is a mini cognition loop: provider call, tools, budgets, repair.
- Tamoz already has the same thing, durable and richer: `Session`, `EffectDispatcher`, Profile.
- Two brains means two sets of bugs and no honest answer to "who thought about this episode?"

**What rev 4 got right — kept, not rewritten:**
- The trust model: the model is untrusted output; Agentic Stream keeps authority.
- The witness gateway for independent proof of real calls.
- The anti-cheat benchmark protocol and the claim ladder.
- The intent catalog contract and receipt semantics.
These move into phases P3, P4, P7 unchanged in substance, compressed in wording.

**Already done — do not redo:**
- P0A decision: Tamoz is the cognition owner (provisional until P1 proves one real call).
- P0B landed on `smarter-tamoz`: ReasoningDocument v2 parser, DiagnosisCatalog, ModelReceipt /
  LogicalCallKey identity, runtime-v1 wire extension (dispatch_policy, prompt body, catalog),
  Profile role resolution with fail-closed verify gate.
- P1 scaffolding exists uncommitted: `episode_model_call.rb`, `local_model_endpoint.rb`.

---

## 3. Target architecture — one spine, many edges

```
  inbound edges                 the spine                    outbound edges
                                           
  gRPC EpisodeRequest ──┐    ┌───────────────────────┐    ┌── gRPC EpisodeEvent stream
  SSE outcome (chan B) ──┤    │ durable inbox         │    ├── stdout renderer (CLI)
  Telegram update ───────┼──▶ │ → compiled graph      │ ─▶ ├── SQLite outbox → Telegram
  CLI stdin/argv ────────┘    │ → effect journal      │    └── CloudEvents projection
                              │ → StreamPart events   │
                              └───────────────────────┘
```

The spine is five rules, already proven elsewhere in the repo:

- **One inbox.** `DurableRunner`. Every request is durable, fenced, recoverable.
- **One program.** A compiled graph. Orchestration lives in nodes and branches.
- **One door.** `EffectDispatcher`. Every model/tool call is journaled.
- **One language.** `StreamPart`. Nodes never emit model events. Receipts become model events at
  the trusted effect boundary. Adapters only translate.
- **One authority.** Profile `model_roles`. The wire names a role; the worker resolves or fails.

### 3.1 The production episode graph

One fixed graph serves all domains. It is compiled in the worker composition
(`bin/tamoz-stream-worker`), not loaded from `--graph`:

```
START → route_kind
  episode:    intake → recall → build_frame → reason → validate
                                                  │       │
                                                  │       ├─ valid ──────▶ decide → END
                                                  │       ├─ tool call ──▶ execute_tool ─┐
                                                  │       ├─ malformed ──▶ repair (once) │ loop bounded
                                                  │       └─ failed ─────▶ END (typed)   │ by graph Limits
                                                  └────────── rebuild frame ◀────────────┘
  reconsider: intake → judge → compensate → END      (deterministic, no model call)
```

- `reason` is the only node that calls a model, and only through `EffectDispatcher`.
- `recall` is added in P5. The P1 slice wires `intake → build_frame` directly.
- `execute_tool` is the only node that calls evidence tools, through the capability host.
- `validate` is deterministic parsing and grounding checks. Never a second model reviewing the
  first.
- `decide` is the deterministic builder as a terminal node: validated document + intent catalog →
  decision. Terminal graph state IS the decision; the runner only translates it to the wire.
- `judge` / `compensate` are deterministic. RECONSIDER never calls a model.
- The loop bound is the graph's own `Limits#max_steps`. Not a counter in an adapter.

### 3.2 Ownership — who owns what

| Concern | Owner | Note |
|---|---|---|
| Cognition (reason, repair, tool choice) | Tamoz graph | the only brain |
| Model selection, credentials, egress | Tamoz Profile | wire names a role |
| Effect durability, receipts, replay of calls | Tamoz `EffectDispatcher` + journal | Go has no journal |
| Skill compilation and pinning | Tamoz skills | digest-bound |
| Memory recall | Tamoz | situation-scoped, authorized |
| Decision proposal | Tamoz `decide` node | deterministic from validated document |
| Decision validation, risk, policy, rate limits | Agentic Stream | independent, fail-closed |
| Aggregate cost reservation / kill switch | Agentic Stream `costcontrol` | Tamoz only enforces the episode envelope |
| Evidence ledger, replay orchestration | Agentic Stream | Tamoz keeps refs, not copies |
| Wire contract (runtime-v1 proto, schemas) | shared, frozen | changes are versioned and coordinated |
| Go native executor | benchmark comparator only | never constructed on a Tamoz route |

### 3.3 Unified IO — what happens to each channel

- **gRPC `Execute`:** stays. Becomes a thin projection — `StreamPart` → `EpisodeEvent`. No
  counters, no budget logic, no second state machine in the adapter. `EpisodeWorker` keeps wire
  contract validation only.
- **gRPC `EvidenceTools`:** stays. Called only by the `execute_tool` node through the capability
  host.
- **SSE channel B:** stays. Inbound adapter that turns outcomes into durable requests.
- **Known divergences, deferred honestly.** Three duplications survive this plan as owner
  decisions in P8: two approval pipelines (stream `ApprovalRelay`, comms approvals), two decision
  types (stream decision-v1, comms `DecisionRecord`), and three auth models (capability token,
  subscriber bearer, bot token). This plan unifies the event/effect spine first and does not
  pretend these are solved.
- **CLI / Telegram:** unchanged. They already run on the spine (inbox, graph, `StreamPart`).
- The proto and CloudEvents formats stay frozen — they are the shared contract with Go. The
  unification is on the Tamoz side: one internal vocabulary, one effect door, one inbox shape.

---

## 4. Hard rules (bind every phase)

1. Real runs call real providers. Fakes stay in tests and are labeled `fixture`.
2. No silent fallback. A failed Tamoz episode terminates typed. Never native, never fixture.
3. The model proposes. It never sets risk, identity, tenant, policy, or authority.
4. No domain Ruby. New domain = spec + catalogs + skills.
5. Every retained byte is digest-verified. Every claim names its evidence level.
6. Fail closed. Missing catalog, unknown role, forged event, stale fence = typed failure.
7. The bar in §1 outranks any phase gate. A gate passed by breaking the bar is a failed gate.

---

## 5. Phases

Each phase is one file. Each gate is testable. Phases land in order.

| Phase | File | One line |
|---|---|---|
| P1 | [PHASE_P1_ONE_REAL_CALL.md](PHASE_P1_ONE_REAL_CALL.md) | Fixed episode graph; one real witnessed model call through the effect journal; honest events. |
| P2 | [PHASE_P2_DURABLE_LOOP.md](PHASE_P2_DURABLE_LOOP.md) | Tool loop and repair as graph branches; unsafe-effect semantics; budgets from receipts. |
| P3 | [PHASE_P3_PROVENANCE_REPLAY.md](PHASE_P3_PROVENANCE_REPLAY.md) | Witness gateway, verified artifacts, offline replay. |
| P4 | [PHASE_P4_INTENT_AUTHORITY.md](PHASE_P4_INTENT_AUTHORITY.md) | Intent catalog replaces every hard-coded domain table; Go validates independently. |
| P5 | [PHASE_P5_SKILLS_MEMORY.md](PHASE_P5_SKILLS_MEMORY.md) | Digest-pinned skills and memory as attributed frame evidence. |
| P6 | [PHASE_P6_RECONSIDER.md](PHASE_P6_RECONSIDER.md) | RECONSIDER moves into the graph; deterministic; catalog-driven compensation. |
| P7 | [PHASE_P7_BENCHMARK.md](PHASE_P7_BENCHMARK.md) | Pilot, freeze, private holdout, adversarial controls, honest metrics. |
| P8 | [PHASE_P8_ROLLOUT.md](PHASE_P8_ROLLOUT.md) | Shadow → active watch-only → calibration-gated automation; kill and drain. |

---

## 6. The claim ladder

Use the narrowest claim the evidence supports. Never higher.

1. **"Plumbing passes"** — fixture contract tests only. (already true)
2. **"A real LLM path exists"** — P1: one witnessed real call; perturbed response changes the
   decision. Does not prove intelligence.
3. **"The real path is durable and replayable"** — P2/P3: crash matrix, receipts, offline replay.
4. **"Domains are authoring-only"** — P4/P5: novel domain, zero Ruby.
5. **"Model X beats baseline Y on benchmark Z"** — P7: preregistered, witnessed, controlled.
6. **"Production-ready"** — P8: shadow, kill switch, SLOs, privacy gates.

Forbidden sentences until P7 passes: "the agent is intelligent", "the agent reasons", "the agent
understands the domain".
