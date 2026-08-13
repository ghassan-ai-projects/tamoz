# Stream-Worker Implementation Audit (independent)

Date: 2026-08-12
Auditor: independent review against `docs/PLAN_TAMOZ_STREAM_BUILD.md` (the B-full plan) and the
joint integration design (`agent-research-lab/integration/`).
Method: direct source inspection of `gems/tamoz-stream`, `gems/tamoz-core`, `gems/tamoz-sqlite`,
`gems/tamoz-agent`, `gems/tamoz-evals`, and `test/`; cross-repo spot-check of `agentic-stream`.
Repo state (first pass): `main` @ `56914de`. The plan doc is marked *"BAR MET — P1–P7 implemented."*

---

## 0. Re-verification (2026-08-12, `main` @ `39ffc1e`) — supersedes §1

A second independent pass after the reverse/learning phases were built (commits `T5: the learning
loop`, `T7: approval relay`, plus three review rounds). **All four gaps from the first pass are now
closed**, verified against source:

| First-pass gap | Now | Evidence |
|---|---|---|
| **T3** evidence pull (reverse channel) | ✅ | `evidence_client.rb` (299 L) — calls `EvidenceTools` scoped by the token, with deadline/cancellation; the token is **opaque** and echoed back (see T1.3 below) |
| **T5** learning loop | ✅ | `outcome_subscriber.rb` (211 L) implements the §9 fail-closed contract — resume by `Last-Event-ID`, at-least-once dedup, `cursor_expired`→audited resnapshot, poison→`subscriber_skipped`, backpressure→`subscriber_too_slow`; `verification_store.rb` is the async machine (`LEARNABLE_VERDICTS = verified, refuted`; `reconcile(reconciliation_version:, source_authority:)`); `situation_memory.rb` for scoped retrieval |
| **T6** reconsideration judgment | ✅ | `reconsideration.rb` (296 L) — `withdraw`/`downgrade`/`let_stand`; `COMPENSATION_RISK` map, `DEFAULT_COMPENSATION_RISK = "R1"`, *"compensation is never safe because it undoes"* |
| **T7** approval relay | ✅ | `approval_relay.rb` (258 L) — the 11-field `ASSERTION_FIELDS` (PROTOCOL §10), single-use `nonce` (replay refused; `Idempotency-Key` separate for transport), `relay_id ≠ approver_id`, `edit_in_place` for withdrawal |

Two security-relevant items from the first pass are **correctly resolved**:

- **T1.3 token custody** (my earlier flag): `evidence_client.rb:14,22` — *"the worker holds NO signing
  secret… the token may not be minted here"*; it is an opaque bearer the stream verifies
  (`situation_request.rb:30`, CONTRACTS §11). The "verify but not mint" property holds by construction.
- **T8.2 the nine stream invariants** are executable tests: `test/stream_invariants_test.rb`,
  `test_invariant_1…9` (no stream-plane concepts, snapshot-mismatch-before-model-call, interrupt
  terminal, experience-requires-reconciled-provenance, assertion-bound approval, withdrawal edits the
  message, compensating-own-risk, watch scoped/bounded, vectors reproduce).

**Updated verdict: Tamoz is functionally complete against the full B-full plan (T0–T7).** The two
residuals are **not functionality gaps**:

1. **T8.1 prompt cache** — the cache-**epoch discipline** exists (`session_records.rb:85`), but
   `cache_control` is not yet plumbed into the model client. This is an efficiency optimization
   (§6.1), not correctness.
2. **T8.3 old-engine retirement** — deferred by design (retire the old `tamoz-stream` engine by a
   later forward migration, after the replacement is proven).

With the agentic-stream side also complete and emitting the typed `outcome.reconciled` feed, **the
full simulator → stream → Tamoz → learning loop can now close end-to-end.** The §1–§5 first-pass
findings below are retained for provenance but are superseded where they conflict with this section.

---

## 1. Verdict

**The supervised forward worker (Channel A) is genuinely built, well-tested, and faithful to the
frozen protocol.** The hardest item in the plan — the streaming event vocabulary (T2) — is done,
along with JCS canonicalization, the containment host, fencing, snapshot verification, and the
typed Decision builder. There is an end-to-end test.

**But "all phases / BAR MET" is accurate only for the forward path (their P1–P7).** Measured against
the full **B-full** plan (T0–T8), four things are **not implemented**, and they are exactly the
pieces that make B-full *"full"* and that close the learning loop:

- **T3 — the reverse evidence channel is not wired.** The worker receives `evidence_tools_endpoint`
  but never calls it. Without a mid-reasoning evidence pull, the running system is **supervised
  B-lite**, not B-full.
- **T5 — the learning loop is not closed.** No Channel B outcome subscriber; `outcome.reconciled`
  → Experience admission is not wired end-to-end (the admission *guard* exists, but nothing feeds it).
- **T6 — reconsideration is routed but not decided.** `RECONSIDER` is accepted as a kind; there is
  no withdraw / downgrade / compensating-intent logic.
- **T7 — approval relay is not implemented.** No `approval_relay.rb`, no `SurfaceDescriptor`
  affirmative-approval change.

So: **the forward supervised episode works; the reverse channel, the learning loop, reconsideration
judgment, and human approval relay do not.** That is a real and defensible milestone — just a
narrower one than "all phases."

---

## 2. Status by phase (evidence-based)

Legend: ✅ implemented + tested · 🟡 partial · ⬜ not implemented.

| Phase | Item | Verdict | Evidence |
|---|---|---|---|
| **T0.1** | RFC 8785 canonicalization + domain digest | ✅ | `Tamoz::Core::JCS` (`core.rb:66` `jcs`, `:84` `digest`, `:90` `verify`); `test/core_jcs_vectors_test.rb` + vendored `gems/tamoz-stream/contracts/canonicalization-vectors.json`. **The #1 prior blocker is fixed.** |
| **T0.2** | Close admission self-cert hole | ✅ | `admission.rb:288` — episodes are `:observed` *only* with an authenticated reconciled-outcome reference; `:83` negative `owner_request_cannot_label_observed`; default no longer yields `:observed`. |
| **T0.3** | Situation-scoped memory (schema + repo) | ✅ | `migrator.rb:958-965` adds `scopes_{situation_type,entity_type,entity_id}` with an all-null-or-all-set CHECK + index `:998`; wired through `memory_repository.rb` (write/read/index) and `agent/memory/surface.rb:131`. |
| **T0.4** | Non-interactive episode mode | ✅ | `episode_worker.rb:89` `unless request.non_interactive`; `situation_request.rb:232` `interrupt_mode: :non_interactive`. |
| **T0.5** | Lane → model-tier mapping | ✅ | `situation_request.rb:106` applies the lane→tier map from config. |
| **T4.1** | Containment capability host | ✅ | `capability_host.rb` (167 L); `test/stream_episode_capability_host_test.rb`. |
| **T1.1** | gRPC + protobuf, generated stubs | ✅ | `gen/runtime-v1_pb.rb`, `gen/runtime-v1_services_pb.rb`; `grpc`/`google-protobuf` pinned in `Gemfile.lock`; `gen.rb` notes a CI drift check. |
| **T1.2** | Handshake declarations | ✅ | `episode_worker.rb`; the proto carries every required field — `contract_version`, `worker_id`, `non_interactive`, `shadow_capable`, `counterfactual_capable`, `emits_complete_replay_ledger`, `supports_kinds`. |
| **T1.3** | Capability-token verification | 🟡 | Implemented as an **opaque HMAC bearer token, not a worker-verified JWT** (their §0.5 note; `situation_request.rb:22`). The worker *carries* the token for evidence calls rather than independently verifying scope. See §4 (security note). |
| **T1.4** | 4th request origin + `(episode_id,attempt_id,fence)` | ✅ | `situation_request.rb` (322 L); `test/stream_situation_request_test.rb`; identity fields present on every wire event (`EpisodeEvent.attempt_id/fence`). |
| **T1.5** | Snapshot digest verification | ✅ | `situation_snapshot.rb` (66 L); `test/stream_situation_snapshot_test.rb`. |
| **T2.1** | Streaming wire vocabulary (the XL item) | ✅ | `episode_stream.rb` (297 L) emits the oneof-discriminated events (`started`→`model_*`→`tool`/`tool_progress`→`budget`→`decision`→`cancelling`→`terminal`); `test/stream_episode_stream_test.rb`. |
| **T2.2** | Budget accounting + cancellation | 🟡→✅ | Wired in `episode_stream`/`episode_worker`; commits `P5-P7 … budget hardening`, `cancellation`. Confirm the budget-kill and supersession-cancel gates in the e2e test. |
| **T2.3** | Complete replay ledger + artifact manifest | 🟡 | Proto has `ArtifactManifest` (prompt/skill-set/tool-catalog/model-policy/contract/memory digests) on `Terminal`; emission + artifact **retention** not fully verified in this pass. |
| **T2.4** | Typed Decision + watch conditions | ✅ | `decision_builder.rb` (140 L); `test/stream_decision_builder_test.rb`. |
| — | End-to-end episode | ✅ | `test/stream_episode_end_to_end_test.rb`; plus `agent_worker_*`, `stream_cognition`, `stream_replay_isolation`. |
| **T3** | Evidence pull (reverse channel) | ⬜ | **No `evidence_client.rb`.** `situation_request.rb:96` passes `evidence_tools_endpoint` into context but nothing calls the `EvidenceTools` stub. The endpoint is carried, never used. |
| **T5.1** | Outcome subscriber (Channel B) | ⬜ | No `outcome_subscriber.rb`; no SSE/CloudEvents consumer. |
| **T5.2** | Async verification state machine | ⬜ | No verification-close machine feeding from `outcome.reconciled`. |
| **T5.3** | Admission reconciled-outcome reference | 🟡 | The *guard* exists (`admission.rb:288`) but nothing delivers a reconciled outcome to it (T5.1 absent), so the loop is not closed. |
| **T5.4** | Situation-scoped retrieval | 🟡 | Storage + repository retrieval by the new scopes is wired (`memory_repository.rb`), but no `situation_memory.rb` and no admission of stream-episode Experiences (depends on T5.1). |
| **T6** | Reconsideration judgment | 🟡 | `RECONSIDER` is routed (`episode_worker.rb:31`, `situation_request.rb:33`); **no** compensating-intent / withdraw / downgrade logic (0 matches). |
| **T7** | Approval relay (Channel C) | ⬜ | No `approval_relay.rb`; `SurfaceDescriptor` affirmative-approval change not present. |
| **T8.1** | Prompt-cache wiring | ⬜ | No `cache_control` in the model client. |
| **T8.2** | `tamoz-evals` stream invariants | ⬜ | `tamoz-evals` has the pre-existing *agent* invariants (e.g. invariant 30, `bounded_plan`), **not** the 9 stream invariants from plan §7. |
| **T8.3** | Retire the old engine | ⬜ (deferred by design) | `migrator.rb:872` — "engine … retired by a later forward migration (T8.3)"; old `stream_store.rb`, `stream_clock.rb`, `connector.rb`, etc. still present, as the plan intends (retire last). |

---

## 3. What is genuinely strong

- **Canonicalization is properly fixed**, not patched: a real JCS module with domain-separated
  digests and a vectors test. This was the load-bearing cross-language blocker and it is closed.
- **Protocol fidelity is high.** The vendored proto is the correct frozen v1: oneof-discriminated
  `EpisodeEvent` with `attempt_id`+`fence` on every event, attempt-scoped `TerminalStatus`
  (`PRODUCED/DECLINED/CANCELLED/FAILED/TIMED_OUT/BUDGET_EXHAUSTED`), `Reconsideration` and
  `ArtifactManifest` messages, `kind/lane/risk_ceiling/allowed_intent_types`.
- **Test coverage on the forward path is real**, including capability-host, snapshot, decision,
  streaming, request, and an end-to-end test — not just unit stubs.
- **The security posture improved on its own merits**: the admission self-certification hole is
  closed regardless of the stream integration.
- **Cross-repo alignment is real (verified):** `agentic-stream` @ `bed8576` now has
  `run-live --worker-socket` (`cmd/agentic-stream/main.go:81,220`), a native Go executor
  (`internal/executor/native`), a conformance harness (`internal/executor/conformance`), concrete
  effectors (`internal/actions/simulated_effector.go`), and SSE-bound notifications. The tamoz
  plan's cross-repo ✅ marks are accurate as of today.

---

## 4. Gaps that matter, prioritized

1. **T3 reverse evidence channel (the B-full/B-lite distinction).** Until the worker actually calls
   `EvidenceTools` mid-reasoning, the deployed system is *supervised B-lite*. If the sealed snapshot
   is always sufficient, that is a fine place to stand — but the "B-full" label should not be used
   until T3 is wired, or the milestone should be relabeled.
2. **T5 learning loop.** The whole strategic reason for the pair (an independent observer feeding
   Experience) is not yet closed: no Channel B subscriber, no verification machine. The admission
   guard is ready and waiting; it needs `outcome_subscriber.rb` + async verification to feed it.
3. **T6 reconsideration judgment.** Routing without judgment means a `RECONSIDER` episode has no
   withdraw/downgrade/compensating behavior — the freezer scenario's "downgrade, not withdraw"
   outcome is not yet reachable.
4. **T7 approval relay** — needed before any R2 human-in-the-loop action can flow to Telegram; also
   gated on the `SurfaceDescriptor` security change.
5. **Security note on T1.3 (verify explicitly).** CONTRACTS §11 specifies a token *"the worker can
   verify but not mint."* An opaque **HMAC** bearer (per the §0.5 note) is fine **if** it is only
   presented back to the stream (which verifies), but a *shared-secret* HMAC that the worker could
   also compute would let a compromised worker mint its own capability tokens. Confirm the worker
   holds no signing secret — only an opaque bearer it echoes back.
6. **T8.2 stream invariants absent from `tamoz-evals`.** The nine release-blocking stream invariants
   (plan §7) are not yet executable tests; the current evals cover the agent, not the worker
   contract.

---

## 5. Recommendation

Relabel the current milestone honestly: **"Supervised streaming forward worker (Channel A) —
complete and tested."** That is a strong, real result and the hardest part of the build.

To reach true **B-full**, the remaining order is: **T3 (evidence pull)** → **T5 (outcome
subscriber + verification, closing the learning loop)** → **T6 (reconsideration judgment)** →
**T7 (approval relay)**, then **T8.2 (stream invariants in `tamoz-evals`)** as the release gate.
T3 and T5 are the two that convert this from "a worker that answers" into "the stream-native
learning agent" that is the actual product thesis.

---

*Files cited are at `main` @ `56914de`. Line numbers are approximate to that commit. Items marked
🟡 "not fully verified in this pass" warrant a direct read before relying on them.*
