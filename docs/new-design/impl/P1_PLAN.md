# P1 — Implementation plan: one real journaled call through the fixed episode graph

Status: **rev 2 — reviewed by gap-searcher + completeness-checker; blockers resolved**. Implementation
starts when this revision is committed to the plan file.

Cross-repo scope: tamoz (Ruby) implements the graph/spine; agentic-stream (Go) fills the wire and
stops constructing the native executor on a `tamoz` route.

---

## 1. Phase bar (from PHASE_P1_ONE_REAL_CALL.md exit gate, unchanged)

| # | Gate | How verified |
|---|---|---|
| 1 | One aquaculture episode runs end-to-end through the fixed graph with the real local endpoint | integration test: worker over gRPC, endpoint = proxy to a real pinned ollama model |
| 2 | Endpoint log digest == Tamoz receipt digest, independently compared | endpoint echoes the canonical request digest in a header + logs raw-body digest; test compares receipt digest to the echoed value and raw-body digest to the transport bytes |
| 3 | Perturb the endpoint's response → selected diagnosis changes | **fixture-labeled** stub serves two different v2 documents; test asserts the checkpoint `document.selected_code` changes (output dependence is a plumbing property) |
| 4 | Same fixed graph runs under an in-process test driver (no gRPC), only adapters swapped | `episode_graph_test` delivers via `DurableRunner` directly |
| 5 | A node emitting `:model_started` is rejected; a fixture graph cannot produce a model event on a `tamoz` route | the projection adapter **raises** on model event types from the graph context (every worker route is tamoz by construction); adversarial test |
| 6 | Crash after completed receipt: redispatch reuses the receipt, no second provider call; crash after `dispatch_started` w/o receipt: typed `unknown`, no blind retry | **worker-restart recovery** crash matrix (re-claim + re-execute), not bare fence+1 redelivery |
| 7 | Unknown role / missing profile / digest mismatch → typed failure before any provider call | testable digest set: snapshot (ReceivedSnapshot.verify), catalog (verify_wire), prompt (new verifier). Profile digest is **unit-level only** in P1 (no wire field) |
| 8 | On `ExecutorName=tamoz` the Go native executor is never constructed | Go: constructor gated behind the worker-socket route + adversarial test `TestExecutorSelectionSkipsNativeOnTamoz` |
| 9 | `rake ci`, `enola check` green (rubocop deferred per owner instruction); no new dependency edge (`tamoz-stream` still not depending on `tamoz-agent`) | repo gates at phase end |

**Finished line:** the claim "A real LLM adapter path exists" is the only claim made. Reports state
provider/model/endpoint/digests/attempt/fence, that telemetry is buffered, and that this is claim
level 2 of 6. **Fixture runs are labeled `fixture` and never shown as evidence of a real model path.**

---

## 2. Current state (verified against code)

- P0B landed on both repos: wire carries `model_policy`, `prompt`, `prompt_version`,
  `diagnosis_catalog_json`/`_sha256`, `executor_name`, `dispatch_policy`, `request_sha256` (ModelStarted),
  `response_sha256` (ModelCompleted). Go populated model_policy (97b176c); prompt/catalog emission
  pending (it needs spec/compiler plumbing).
- P1 scaffolding uncommitted: `episode_model_call.rb` (raw call, not journaled), `local_model_endpoint.rb`
  (canned responses — must be reworked, see G1).
- **ollama is installed with pinned local models** (`gemma4:latest`, `brain:latest`) — the real local
  endpoint for gate 1 is a proxy in front of ollama.
- `tamoz-core/lib/tamoz/stream_part.rb` EXISTS: `StreamPart` + `StreamPartContract::CORE_TYPES`
  (16 types, no model events yet) + `StreamSink`. T2 extends it; no new vocabulary (R4).
- The worker launcher still requires `--graph FILE`; fixture graphs emit fake `provider: "test"`
  model events (R3) — both killed by this phase.
- `EpisodeStreamAdapter` (episode_stream.rb:180-308) counts events, enforces budgets, maps terminals —
  collapses to a projection.
- `DecisionBuilder` (decision_builder.rb) builds decisions from graph outcome + hard-coded tables;
  runner `emit_decision` + `open_verifications` (situation_request.rb:391-464) are runner-side
  orchestration — deleted/reduced by this phase.
- Journal: `prepare` derives keys from `(thread_id, namespace, execution_id, task_id, call_index,
  operation)`, enforces `active_execution == execution`, and the durable executor overrides the run
  context's `execution_id` with a claim-time UUID (durable_request_executor.rb `request_context`,
  request_inbox_claimer.rb:29). **Cross-fence receipt reuse therefore requires logical-key journal
  addressing.** `effect_key` is a free TEXT column (no format check); unsafe crash-after-start is
  already `:unknown` (effect_preparation.rb:151-165).
- RubyLLMModel#generate has an emitter path (ruby_llm_model.rb:46-54) — the episode path calls it
  WITHOUT an emitter (no second, receipt-less event path).

---

## 3. Target architecture (P1 slice)

```
START → intake → build_frame → reason → validate → decide → END
```

- `intake`: validates the envelope (kind must be DIAGNOSE — RECONSIDER fails closed typed in P1),
  resolves the model role per request (fail-closed), copies the verified snapshot + P0B wire fields
  into graph-visible state channels. No model call.
- `build_frame`: deterministic. Verifies catalog digest (`DiagnosisCatalog.verify_wire`) and prompt
  digest (new verifier); assembles the frame (trusted policy section + untrusted snapshot section).
  No model call.
- `reason`: the ONLY model-calling node. Calls `EpisodeModelCall` through `EffectDispatcher.run`
  (`safety: :unsafe`, `logical_key:` = the P0B logical call key). Produces `{raw_response, receipt}`
  (raw response is the journaled result — codec-safe; receipt reconstructed on replay).
- `validate`: deterministic. `ReasoningDocument.parse` (v2) + grounding checks (evidence_refs against
  frame facts; catalog codes; probability sum). No model call.
- `decide`: deterministic. Validated document + injected risk table (data until P4) → terminal
  `:decision` state. The runner NEVER builds decisions — it only translates terminal state to the wire.

State channels (fixed graph): `episode`, `snapshot`, `frame`, `document`, `decision`, plus the P0B
wire fields under `wire`, and the existing `situation_memory`/`memory_record_digests` (immutable,
P5-owned) / `reconsideration` (P6-owned, unused in P1).

---

## 4. Tamoz-side tasks

### T1 — Journaled EpisodeModelCall (rewrite episode_model_call.rb) — the core seam

**Journal mechanics (verified):** prepare derives the key from `(thread_id, namespace, execution_id,
task_id, call_index, operation)`; the durable executor overrides `execution_id` with a claim-time
UUID; so cross-fence receipt reuse needs **logical-key journal addressing**:

- `EffectJournalKey.logical(guard:, logical_key:)` → `"logical:" + hexdigest(JSON([to_key]))` (free
  TEXT column, no migration).
- `EffectJournal#prepare` gains `logical_key: nil` (keyword; default preserves today's behavior
  byte-identically): when present, the effect key is the logical digest and `verify_identity!` binds
  only `(thread_id, namespace, safety, request_digest)`. `EffectJournal#logical_key(logical_key)`
  returns the same digest for complete/reconcile.
- `EffectDispatcher.run` gains `logical_key: nil`: `key = effects.logical_key(...)`, `prepare(..., 
  logical_key:)`. `EffectCompletion`/`EffectReconciler` look up by the passed key — unchanged.
- Same request bytes on fence+1 → same logical key → `:return` of the completed receipt (no provider
  call). Changed frame → different request_digest → different key → fresh call. `MAX_ATTEMPTS` note:
  only enforced on the reconcile path today; the episode path uses `:unsafe` so a crash after
  `dispatch_started` is a permanent `:unknown` — no blind retry (documented, not fixed, in P1).

**Call shape:** `perform` returns the **raw response String** (codec-safe). After `:succeeded`
(fresh OR reused), `EpisodeModelCall` builds the `ModelReceipt` from the outcome + invocation +
resolved role; `receipt.effect_id = logical_call_key.to_key`; `response_digest = digest(raw)`.
`InvocationIdentity(attempt_id:, fence:, graph_task:, stage:, global_ordinal:)` is built per
invocation — `global_ordinal` is the **ordinal source** for wire events (replay emits identical
ordinals). `safety: :unsafe`.

**Trusted event emission:** after `:succeeded`, emits `model_started` (with `request_sha256`) and
`model_completed` (with `response_sha256` + usage) as StreamParts through the **trusted wire emitter**
(implemented by the stream projection via `StreamSink`), never through the graph's Context emitter.
On `:unknown`/`:failed`: nothing model-like; the runner produces the typed terminal. **The model port
is called with no emitter** (`model.generate(stage:, system:, prompt:)`).

### T2 — StreamPart vocabulary (extend tamoz-core, no new vocabulary)

- Extend `StreamPartContract::CORE_TYPES` with `:model_started, :model_delta, :model_completed,
  :decision, :terminal` (snake_case, consistent with the existing 16).
- `StreamSink` is the trusted channel contract. The graph's Context emitter and the trusted wire
  emitter are distinct objects with distinct method names (`emit(type, namespace, data, run_id:,
  task_id:)` for Context; `emit(stream_part)` for the trusted channel) — no signature confusion.

### T3 — Fixed episode graph (new, tamoz-agent/lib/tamoz/agent/episode_graph.rb)

- `Tamoz::Agent::EpisodeGraph.build(checkpointer:, nodes:, ...)` — one definition compiled in process,
  used by BOTH `bin/tamoz-stream-worker` and the in-process test driver (gate 4).
- Nodes delegate to injected `EpisodeNodes` ports (pattern: session.rb `build_definition` +
  session_nodes.rb). The **decision builder is injected as a port** (lives in tamoz-stream, per the
  phase doc), and the risk table is injected as **data** until P4 deletes it.
- `kind != :diagnose` (RECONSIDER) → typed failure before the graph (out-of-scope kind must terminate
  typed; no `route_kind` branch in P1).
- `--graph FILE` removed from the production launcher.

### T4 — Emission boundary (in the projection adapter, tamoz-stream)

- `EpisodeStreamAdapter#emit` (the graph Context boundary): the `:model_started/:model_delta/
  :model_completed` case arms are REMOVED and **raise** on model event types (typed failure, not
  silent drop). Every worker route is tamoz by construction (EpisodeWorker::WORKER_NAME = "tamoz").
- The trusted wire emitter (StreamSink-backed, per-run) is the only path that produces model events;
  it draws ordinals from `receipt.invocation.global_ordinal`.

### T5 — EpisodeStream collapse (tamoz-stream)

- `EpisodeStream` keeps wire-event construction; `#model_started`/`#model_completed` gain
  `request_sha256:`/`response_sha256:` params (proto fields exist).
- `EpisodeStreamAdapter` keep/delete (explicit):
  - **delete:** `@model_calls/@tool_calls/@usage/@budget_emitted` counters, `emit_budget`,
    `enforce_mid_run_budget!`, `wall_time_exceeded?`, `model_calls_exceeded?`, `accumulate`,
    `wire_usage` accumulation, budget-aware terminal overrides.
  - **keep:** `started`, `diagnostic` (typed_code path), `terminal` mapping (produced/failed/
    cancelled from the durable run result only — no budget overrides until P2), and the ordering
    guarantee that the trusted emitter and Context events merge into ONE sequence-numbered stream
    (single `EpisodeStream` per run).
- `EpisodeRunner#run` keeps envelope validation, snapshot verify, recall injection, durable delivery;
  `emit_decision` becomes TRANSLATION of the terminal `:decision` state → wire decision event (no
  builder); **`open_verifications` is deleted from the runner** (moves to the Go side / subscriber
  path in a later phase); `build_artifact_manifest`/`retain_manifest_artifacts` are kept and gain
  the prompt under `prompt_sha256`.

### T6 — Decide node + builder

- The **builder stays in tamoz-stream** (`DecisionBuilder` or its deterministic core), injected into
  the decide node as a port; `ACTION_RISKS`/`RISK_ORDER` are injected as data (deliberate P1
  exception, deleted in P4).
- The decide node produces the terminal `:decision` state from validated document + allowlist; the
  runner serializes it. **Gate 3 asserts on the checkpoint `document.selected_code`** (decision-v1
  stays frozen in P1; selected_code/evidence_refs enter the wire schema in P4 as a coordinated
  change).

### T7 — Worker composition + per-request model authority (bin/tamoz-stream-worker)

- New flags: `--profile PATH` (Profile file), keep `--database`, `--tenant`, `--socket`/`--port`;
  drop `--graph`.
- **Per-request** role resolution at admission (EpisodeRunner#run or intake): blank `model_policy`,
  unknown role, or incomplete role → typed FAILED terminal before any provider call
  (`ModelCall.resolve_role`, fail-closed). The resolved `ModelRole` builds the `RubyLLMModel` for
  THIS request (`api_base` from `normalized_settings`, or the local-endpoint base for tests).
- A profile fixture points a role at `LocalModelEndpoint#base_url` for the integration tests.
- The episode model port is called with NO emitter (G7).

### T8 — Envelope payload extension (wire → graph state)

- `EpisodeRequestEnvelope#payload` gains: `prompt`, `prompt_sha256`, `diagnosis_catalog_json`,
  `diagnosis_catalog_sha256`, `model_policy`, `executor_name`, `dispatch_policy` (mirroring the
  snapshot_json/snapshot_sha256 pattern). `EpisodeRunner#run` merges them into graph-visible state
  so build_frame/reason/validate can consume them.

### T9 — Frame builder + digest (new, tamoz-agent)

- Defines the frame data shape, canonical bytes (JCS), a `frame_digest` domain, the snapshot-fact
  ref scheme (`fact:<id>`), and deterministic ordering (policy section, catalog descriptions in
  catalog order, facts). `validate` grounds `evidence_refs` against frame facts.
- Prompt digest verifier: canonical prompt bytes (must match the Go compiler's canonicalization —
  P1-Go detail, test parity with a fixture) + digest domain; `build_frame` fails closed on mismatch.

### T10 — Aquaculture DO-crash domain (data only)

- Spec + diagnosis catalog (codes incl. `unknown`, per DiagnosisCatalog), snapshot facts from the
  round-3 DO material (`pond.dissolved_oxygen`/`aerator_current` family), prompt fixture instructing
  exact v2 JSON output + `fact:` refs. Zero hard-coded answers; the graph is domain-agnostic.

### T11 — Tests

- `episode_model_call_test` — journaled call, logical key, receipt reuse, unknown ambiguity,
  digest equality with the fixture endpoint.
- `episode_graph_test` — fixed graph under the in-process driver (gate 4); perturbed response
  changes `document.selected_code` (gate 3, fixture stub labeled `fixture`); catalog/prompt/role
  failures typed before any call (gate 7).
- `episode_emission_test` — node-emitted model event RAISES; fixture graph cannot produce one
  (gate 5).
- `episode_stream_projection_test` — StreamPart → EpisodeEvent translation, unique ordinals,
  request/response digests in proto fields.
- **Crash matrix** (gate 6) — worker-restart recovery: re-claim + re-execute the same request after
  a completed receipt → journal `:return` (no second provider call), replayed stream ordinals equal
  the first run's; after `dispatch_started` without receipt → typed `unknown`.
- **Real endpoint run** (gates 1-2) — worker over gRPC with `--profile` fixture pointing at the
  local endpoint in **proxy mode** (real pinned ollama model); endpoint log digests == receipt
  digests (echoed header + raw-body log), compared independently. Real-run tests labeled `real`;
  fixture tests labeled `fixture`.

## 5. Go-side tasks (agentic-stream)

- Verify proto parity (already landed, 1d55801). `worker_executor.go`: emit the prompt body,
  model_policy (done, 97b176c), and diagnosis catalog; fill the formerly-unset digest fields
  (worker_executor.go:517-530).
- **Gate 8 (BLOCKER fix):** `worker_runtime.go:111-126` constructs `nativeexecutor.New(...)` on every
  boot regardless of route. Gate the constructor behind the worker-socket route (skip native
  construction when `WorkerSocket` is configured); adversarial test
  `TestExecutorSelectionSkipsNativeOnTamoz` asserts the constructor is never invoked on a tamoz
  route (injectable constructor), not merely that `r.Executor` was replaced.
- The produced decision flows through the existing `decisions.Validate` (acceptance test in the
  cross-repo integration step).
- Prompt canonicalization parity: the Ruby frame's canonical prompt bytes must digest-match the Go
  compiler's `prompt_sha256` (fixture-verified in this phase).

## 6. Verification sequence (owner instruction: no full suite until the end)

1. Targeted Ruby tests per task (T11 list) as implemented — fixture tests first, then the real
   endpoint run.
2. Go: `go build ./...` + `TestExecutorSelectionSkipsNativeOnTamoz` + worker-executor digest test.
3. **Cross-repo integration** (gates 1, 8): spawn `bin/tamoz-stream-worker` (`--profile` fixture,
   endpoint in proxy mode) and drive it from agentic-stream (run-live with `--worker-socket`, or a
   Go test dialing the socket): PRODUCED terminal + accepted decision + no native construction.
4. Phase end: one full `rake ci` (gate 9) + `enola` diff_snapshot (architecture delta) + Go suite.
5. Cross-repo handoff note for anything the Go side cannot complete in this session.

## 7. Deliberate P1 deferrals (stated, not hidden)

- Profile digest on the wire (no field; unit-level only).
- selected_code/evidence_refs in decision-v1 (frozen; P4 coordinated change).
- `open_verifications` moves to the Go side/subscriber path (deleted from the runner now).
- Budgets from receipts, tool loop, repair, recall node: P2/P5.
- `MAX_ATTEMPTS` on the execute path: documented (unsafe semantics make it harmless), not fixed.
