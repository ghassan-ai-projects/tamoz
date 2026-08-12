# Build Plan: Tamoz — Streaming Stream Worker (Option B-full)

Status: revised after dual-repo audit (2026-08-12) — corrections below; implementation loop live
Target: **Tamoz becomes a supervised streaming gRPC episode worker** for Agentic Stream, so that
`simulator → stream → Tamoz → Decision → effect` runs as a supervised loop, and the reconciled
Outcome feeds Tamoz's learning loop. Stream support is Tamoz's **main offering**, so this plan
carries the full worker — Channel A (episode), the reverse evidence channel, Channel B (learning),
and Channel C (approval relay) — not a reduced slice.

Grounded in: the Tamoz source audit (repo `~/my-projects/tamoz`, branch **`main`** @ `2696350`,
post-P18), the **frozen** `runtime-v1` proto in agentic-stream (working tree @ `031fcbb` + uncommitted
fields 59/60), and `integration/{TAMOZ_RESPONSIBILITIES,PROTOCOL,LIFECYCLES,CONTRACTS,THREAT_MODEL}.md`.
The agentic-stream counterpart is `PLAN_AGENTIC_STREAM_BUILD.md` (§B lists what the stream still owes
this plan). **§** references are to `TAMOZ_RESPONSIBILITIES.md` unless noted.

## 0.5 Audit corrections (2026-08-12; supersede the text below where they conflict)

| Plan claim | Correction |
|---|---|
| `Migrator CURRENT_VERSION=8` | **10** — ordinals 9/10 consumed by ADR-049; new work is **MIGRATION_11+** (T0.1 re-seal = 11, T0.3 scopes = 12) |
| T1.3 "JWT capability-token verification" | Stream issues **opaque HMAC-SHA256 tokens** (`v1.<keyID>.<claims>.<sig>`), verified only by the stream's EvidenceTools server. The worker **never verifies a signature** — it carries the token on evidence calls. Worker-side verification = request identity (`episode_id/attempt_id/fence`) + snapshot digest (T1.5) + self-limiting proposals to the request's `risk_ceiling`/`allowed_intent_types`. JWT would be dead code against the current stream. |
| T2.1 "episode.started → …" dotted vocabulary | The wire uses **oneof-discriminated events**: `started` (seq 1, server/worker-emitted), `model_started`/`model_delta`/`model_completed`, `tool` (REQUESTED/STARTED/COMPLETED/BLOCKED), `tool_progress`, `budget` (`budget.updated`; **mandatory when the request carries numeric budgets**), `decision` (`decision.proposed`), `diagnostic`, `cancelling`, `terminal` (exactly one). Sequence must be exactly 1,2,3,…; every event carries `(episode_id, attempt_id, fence)`; a `decision` is required before `PRODUCED`. |
| "Prefer a vetted JCS gem" | **No JCS gem exists on RubyGems.** Implement RFC 8785 in `tamoz-core`, driven by `contracts/canonicalization-vectors.json` as the executable spec. |
| Stream owes S3 (conformance harness) / S1/S2 | **Already built** in agentic-stream: `internal/executor/conformance/`, `run-live --worker-socket` (UDS, optional mTLS), per-dispatch opaque capability issuance, simulated effector, simulator ingest. The plan's §6 table is stale on these rows. |
| Channel B "P6.1 log done" | Correct — but it is a **cursor-paginated durable log** (no SSE endpoint, no `outcome.recorded`/`outcome.reconciled` emitters). T5 stays blocked on the stream. |
| Decision schema location | JSON Schema (`decision-v1.json`, `urn:situation-runtime:schema:decision:v1`), **not protobuf**; `DecisionProposed` carries opaque canonical JSON + `decision_sha256`. |
| Completion bar | §7 below. |

Stream proto is **mid-change in an uncommitted worktree** (`EpisodeRequest.prompt_sha256`=59,
`objective_sha256`=60). Tamoz vendors a **pinned copy** of the proto + schemas + vectors; cross-repo
drift is checked against the vendored pin, not the live worktree.

---

## 0. What Tamoz already has vs. what B-full needs (verified)

**Reuse as-is (already built, tested):**
- Durable **request inbox** + lease/fence/stale-request machinery (`request_inbox_*`) — the episode
  request rides this.
- **Graph executor**, planning, review, verification, checkpoints.
- **Memory** (experience/knowledge/wisdom) + admission + promotion.
- **MCP** client/server (`tamoz-mcp`, active Streamable-HTTP work) — reused for the evidence channel.
- **tamoz-comms** + Telegram — the approval delivery surface.
- Checksummed **Migrator** (`CURRENT_VERSION=10`) — new work is forward migrations only.

**Net-new or broken (this plan):**
- **No gRPC anywhere** — the entire Channel A/evidence surface is new.
- **`Core.canonical` is not RFC 8785** — every snapshot/decision digest disagrees with Go.
- **Memory scopes** are `tenant/user/project/session` only — no situation/entity dimension.
- **Admission self-cert hole** — `independently_observed` defaults true (`admission.rb:296`).
- **`SurfaceDescriptor`** caps approvals at `none`/`deny_only`.
- **Interrupt = wait/resume** — no non-interactive episode mode.
- The old **`tamoz-stream` engine** is present (watermarks, no timers) and must be **inverted**, not
  extended. None of the §4 target files exist yet.

---

## 1. The gem: `tamoz-stream`, inverted

From a stream engine into a **stream-native worker capability** (`§4`). Target layout:

```text
gems/tamoz-stream/lib/tamoz/stream/
  situation_request.rb    # 4th request origin: episode → inbox → turn
  situation_snapshot.rb   # consumed + digest-verified, never produced
  episode_worker.rb       # gRPC EpisodeWorker service (server)
  episode_stream.rb       # emits the wire event vocabulary from graph execution
  evidence_client.rb      # EvidenceTools gRPC client (reverse channel)
  capability_host.rb       # containment: allowlisted, effect-free tool surface
  decision_builder.rb     # typed Decision, intents, watch conditions
  reconsideration.rb      # kind: RECONSIDER + compensating intents
  outcome_subscriber.rb   # Channel B consumer, durable resume
  approval_relay.rb       # Channel B/C bridge into tamoz-comms
  situation_memory.rb     # situation-scoped retrieval
```

Net: Tamoz **deletes more engine code than it writes**, and gains a capability it cannot deliver
today. The old engine files and their MIGRATION_4/5 tables are retired by a **forward** migration in
Phase T8, never edited out.

---

## 2. Phased PR plan

Ordered by dependency; the "Blocked by" column is authoritative. Phases T0/T4 have no gRPC
dependency and start now.

### Phase T0 — Foundations (Tamoz-internal, start immediately)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T0.1** | **JCS canonicalization as a versioned re-seal migration** (`§5.1`, CONTRACTS §13). Replace `Core.canonical` with true RFC 8785: ES `Number::toString` numbers, UTF-16 key order, minimal escaping, reject `NaN`/`±Inf`/`-0`/dupe-keys/out-of-range ints. Domain-separated `sha256:`-prefixed digest. **This re-seals many stored digests** — the reviewed-plan/action digest (`deliberation.rb:306`), `memory_id`, egress pins, capability/skill/profile/wisdom seals, invariant-16 cache epochs. Ship as a new digest version with a re-derive migration, not an in-place edit. | `gems/tamoz-core/.../core.rb`; every `Core.canonical` caller | Reproduce all 16 accept + 2 native_only + refuse 8 reject vectors; **Go and Ruby byte-identical** over the shared vectors; re-seal migration re-derives every seal with no orphaned identity | — (load-bearing; do first) |
| **T0.2** | **Close the admission self-cert hole** (`§5.8` interim). Remove the `independently_observed` default; a self-certified turn admits only as `:reported`, never `:observed`. Keeps the shipping agent working (this method serves user turns too, `session_memory.rb:88`). | `admission.rb` | Old defaulting path no longer yields `:observed`; regression test pins it | — |
| **T0.3** | **Situation-scoped memory migration** (`§5.6`). Forward `MIGRATION_12`: scope keys `situation_type/entity_type/entity_id` + index columns; extend `validate_scopes`; authorize-before-rank filtering. | `record.rb`, `memory_repository.rb`, `migrator.rb` | New scopes validated/bounded; retrieval filters before ranking (acceptance test lands in T5.4 when data exists) | — |
| **T0.4** | **Non-interactive episode mode** (`§5.5`). A graph `interrupt` becomes a typed terminal failure `interrupt_in_non_interactive_episode`, not a wait. | `graph/executor.rb`, `graph/interrupt.rb` | An interrupting skill fails fast, does not consume wall-clock budget | — |
| **T0.5** | **Lane → model-tier config** (`§6.3`). Declared map `fast/deep/batch` → Tamoz model tier. | config | `fast` uses cheap tier, `deep` strong tier, from config not inference | — |

### Phase T4 — Containment (safety; gates the worker going live)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T4.1** | **Stream-episode capability host** (`THREAT_MODEL §4`). Build the episode tool surface from an **allowlist that holds no reference** to `write_file`/`edit_file`/`bash`/check-runner/MCP-client/`interrupt`/`delegate`/egress/`EffectJournal`/memory-writes. The worker runs *inside* this host. Prove with a **dependency-direction test** + injection corpus. | `capability_host.rb` | Dependency test fails if the episode path gains an effectful reference; injection corpus reaches no filesystem/effector/MCP/memory-write call | T0.4 |

### Phase T1 — gRPC worker skeleton (Channel A server)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T1.1** | **gRPC + protobuf in Ruby.** Add `grpc`, `google-protobuf`, `grpc-tools` to the gemspec; vendor `runtime-v1.proto`; generate Ruby stubs (`grpc_tools_ruby_protoc`) into `tamoz-stream/lib/tamoz/stream/gen/`; Rake `stream:proto` task + CI drift check. | gemspec, Rakefile, `gen/` | `require` of generated stubs loads; codegen reproducible | Program: proto frozen (✅ stream side) |
| **T1.2** | **`episode_worker.rb` — the `EpisodeWorker` service.** Handshake declares `non_interactive:true`, `worker_id`, `contract_version`, `shadow_capable`, `counterfactual_capable`, `emits_complete_replay_ledger:true`, `supports_kinds:[DIAGNOSE,RECONSIDER]`; refuse on major contract mismatch. | `episode_worker.rb` | Handshake negotiates; a bad contract major is refused | T1.1 |
| **T1.3** | **Opaque capability-token handling** (CONTRACTS §11 as implemented). The stream's token is an opaque HMAC-SHA256 value verified only by the stream's EvidenceTools server. The worker: validates the **request identity** (`episode_id/attempt_id/fence` match the dispatch), verifies the **snapshot digest** (T1.5), and self-limits proposals to `allowed_intent_types`/`risk_ceiling`. Carries the token verbatim on evidence calls. No worker-side key exists; fail closed on missing/inconsistent identity. | `episode_worker.rb` | A mismatched request identity or snapshot digest terminates before any model call; evidence calls carry the token | T1.1, T0.1 |
| **T1.4** | **`situation_request.rb` — the 4th request origin.** On `Execute`, mint a stable request id → enqueue to the inbox → run the graph inside T4.1's host, so a crash mid-episode resumes from a Tamoz checkpoint. **Key the inbox on `(episode_id, attempt_id, fence)`; stamp all three on every emitted event and Decision** (invariant #4 — a `fence+1` re-dispatch must not dedupe against an in-flight old attempt). Idempotent on redelivery. | `situation_request.rb` | One episode → exactly one logical turn under a stable id; survives a crash between admission and execution; a `fence+1` redelivery does not return stale output | T1.2, T4.1 |
| **T1.5** | **`situation_snapshot.rb` — verify, never produce.** Recompute + constant-time compare the snapshot digest on receipt; fail loudly on mismatch **before any model call**. | `situation_snapshot.rb` | A tampered/drifted snapshot terminates the episode with a typed error before the first model call | T0.1 |

**Phase T1 exit:** a DIAGNOSE happy path — snapshot in, graph runs in the containment host, a typed
Decision comes back — passes the **stream's executor conformance harness** (stream item S3).

### Phase T2 — The streaming vocabulary + supervision (the B-full core / hardest phase)

This is what makes the episode *supervisable*. It instruments Tamoz's model/graph execution to emit
the wire lifecycle as it runs, and to honor budgets and cancellation.

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T2.1** | **`episode_stream.rb` — emit the wire vocabulary.** The wire uses oneof-discriminated events: `started` (seq 1) → `model_started`/`model_delta`/`model_completed` → `tool` (REQUESTED/STARTED/COMPLETED/BLOCKED) → `tool_progress` → `budget` (`budget.updated`; mandatory when the request carries numeric budgets) → `decision` → `cancelling` → `terminal` (exactly one). Sequence exactly 1,2,3,…; every event carries `(episode_id,attempt_id,fence)`. Tamoz's internal graph/checkpoint events stay internal; only this vocabulary crosses. **Invasive:** the model client and graph executor must surface per-call progress + token/cost accounting mid-turn. | `episode_stream.rb`, model client, `graph/executor.rb` | Over 10 consecutive episodes the stream receives the full event stream with correct sequence + identity on every event; a decision precedes `PRODUCED` | T1.4 |
| **T2.2** | **Budget accounting + cancellation.** Track tokens/cost/tool-calls/wall-time against `EpisodeBudget`; emit `budget.updated`; terminate `timed_out` on local exhaustion; on RPC-context cancel (supersession) abort, leave a resumable-but-abandoned checkpoint, terminate `cancelled`. | `episode_stream.rb`, `episode_worker.rb` | A budget-ceiling episode is killed and reports `timed_out`; a supersession cancel aborts mid-episode within the grace period leaving a resumable checkpoint | T2.1 |
| **T2.3** | **Complete replay ledger + artifact manifest.** Make `emits_complete_replay_ledger` truthful: emit every model/tool event the stream needs to reproduce the Decision. On terminal, emit the per-episode **artifact manifest** (prompt/skill-set/tool-catalog/model-policy/contract/retrieved-memory digests) and **retain** the named artifacts. | `episode_stream.rb`, artifact store | A stream `recorded` replay reproduces the accepted Decision **without** re-running Tamoz; a `shadow` run reports memory/skill digest diffs from the manifest | T2.1 |
| **T2.4** | **`decision_builder.rb` — typed Decision + watch conditions.** Build the Decision + intents to the frozen decision schema; digest via T0.1. At low confidence, prefer proposing an `install_watch_condition` intent (CEL-compilable expression) over a consequential action. | `decision_builder.rb` | A scorecard rewards a watch condition over an R2 action at low confidence; the expression compiles under the stream's restricted CEL | T1.5, T0.1 |

**Phase T2 exit:** the stream can *supervise* — budget-kill, cancel, and replay-from-ledger all
work. This is the supervised forward loop and the core of the offering.

### Phase T3 — Evidence pull (reverse channel)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T3.1** | **`evidence_client.rb` — `EvidenceTools` gRPC client.** Call the stream's evidence tools mid-reasoning, scoped to the token's `tools/tenant/entity/time_range`; handle `ArtifactRef` + truncation. | `evidence_client.rb` | A mid-reasoning evidence call returns data; a call outside token scope is refused | T1.3 |
| **T3.2** | **Wire evidence into the episode tool surface** so a plan/skill step can request evidence during reasoning — through the T4.1 host (read-only, no effects). | `capability_host.rb`, graph tools | The episode can fetch evidence but still cannot reach any effectful capability | T3.1, T4.1 |

### Phase T5 — The learning loop (Channel B; needs stream Channel B live)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T5.1** | **`outcome_subscriber.rb` — Channel B consumer.** SSE/CloudEvents with durable resume and the §9 fail-closed paths: `cursor_expired`→audited resnapshot, poison-skip after bounded retry, backpressure disconnect, at-least-once dedup on `source`+CE `id`, per-subscriber credential. | `outcome_subscriber.rb` | A worker offline for a command's whole lifecycle receives every outcome on reconnect; `cursor_expired` forces a resnapshot; a poison event is skipped | stream S: Channel B outcomes |
| **T5.2** | **Async verification.** Attempt ends `produced`; a verification row opens `awaiting`, closes on `outcome.reconciled` (days later). Tamoz never reports acceptance/verification as a worker state. | verification store | A Tuesday episode admits its Experience from a Friday outcome with provenance intact | T5.1 |
| **T5.3** | **`admit_episode` requires an authenticated reconciled-outcome reference** (`§5.8` full). `outcome_id/outcome_digest`, `command_id`, `source_authority` (verified vs stream key), `reconciliation_version`, `observation_status∈{verified,refuted}`, `episode_id+attempt_id`. Enforced at the memory boundary; the `:observed` self-cert path (already downgraded in T0.2) now requires the reference. | `admission.rb` | A caller cannot self-certify; no Experience from another executor's episode, an unreconciled/`inconclusive`/`superseded` outcome, or a forged `source_authority` | T5.1, T0.1 |
| **T5.4** | **`situation_memory.rb` — situation-scoped retrieval** over T0.3's schema; relatedness authority defaults to *same tenant AND same entity type*. | `situation_memory.rb` | A related-entity second occurrence retrieves the first's Experience; out-of-boundary retrieves nothing; zero cross-boundary recall | T0.3, T5.3 |

### Phase T6 — Reconsideration (stream RECONSIDER admission is ✅ on stream side)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T6.1** | **`reconsideration.rb` — `kind: RECONSIDER`.** Read prior Decision/commands/outcomes/correction; decide withdraw / **downgrade** / let-stand; propose compensating intents that carry **their own** risk class. | `reconsideration.rb` | The freezer golden trace produces a **downgrade**, not a withdrawal; a compensating intent is classified at its own risk, not assumed safe | T2.4, stream RECONSIDER admission |

### Phase T7 — Approval relay (Channel C; needs stream principals + Channel B approvals)

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T7.1** | **`SurfaceDescriptor` affirmative-approval mode** — a material security-boundary change (also changes the surface `definition_digest`); its own review. | `surface_descriptor.rb` | Affirmative approval is expressible; the digest/compat change is migrated | **owner + security review** |
| **T7.2** | **`approval_relay.rb` — Channel B/C bridge.** Deliver `approval.requested` on the bound channel (Telegram) via tamoz-comms; return a receipt; submit the answer with `Idempotency-Key` + a **signed assertion binding all 11 fields** (PROTOCOL §10) + a **durable single-use nonce**; edit-in-place on `approval.withdrawn`; own escalation/roster; authenticate the human and map to a stream `approver_id` (`relay_id ≠ approver_id`). | `approval_relay.rb` | A supersession updates the technician's message before the deadline; a relayed approval never bypasses the stream's revalidation | T7.1, T0.1, stream S: principals + approval events |

### Phase T8 — Efficiency, evals, retirement

| # | Work | File(s) | Gate | Blocked by |
|---|---|---|---|---|
| **T8.1** | **Prompt-cache wiring** (`§6.1`). Apply invariant-16 prefix stability to the episode prefix; **epoch key = digest of the assembled prefix** (spec/prompt/skill-set/tool-catalog/decision-schema/model-policy/retrieved-memory/contract), not the spec digest; plumb `cache_control` into the model client. | model client, prompt assembly | Ten consecutive episodes of one spec show cache hits on the full prefix | T2.1 |
| **T8.2** | **`tamoz-evals` invariants** (`§7`). Encode the 9 stream invariants + the 9 shared vectors as executable tests. | `tamoz-evals` | All nine clauses + vectors reproduce | after the phase each covers |
| **T8.3** | **Retire the old engine by forward migration.** After an owner retention/export decision for admitted events/situation versions/trigger evaluations, add `MIGRATION_N` dropping the stream tables, then delete the old `tamoz/stream/*` engine files + tests. | `migrator.rb`, `gems/tamoz-stream` | Old engine gone; no database at any prior version is corrupted | replacement fully live |

---

## 3. Critical path to a first supervised DIAGNOSE episode

```
T0.1 canonical ──┐
T0.4 interrupt ──┼─→ T4.1 containment ─→ T1.1 gRPC ─→ T1.2 handshake ─→ T1.3 token
                 │                                          │
                 └────────────────── T1.5 snapshot ─────────┤
                                                            ▼
                              T1.4 request origin ─→ T2.1 stream vocab ─→ T2.2 budgets/cancel
                                                            │
                                              T2.4 decision builder ─→ [conformance harness]
                                                            ▼
                                    FIRST SUPERVISED sim→stream→Tamoz→Decision loop
```

Everything after — T2.3 (replay ledger), T3 (evidence pull), T5 (learning), T6 (reconsideration),
T7 (approvals), T8 (cache/evals/retire) — extends the working loop without changing its shape.

**Suggested first PRs:** (1) T0.1 canonicalization + vectors; (2) T0.2 admission downgrade; (3) T0.4
non-interactive + T4.1 containment host; (4) T1.1 gRPC codegen + T1.2 handshake skeleton against the
stream's conformance harness; (5) T1.3–T1.5; (6) T2.1 the streaming vocabulary.

---

## 4. The hard part, named

**T2.1 (the streaming vocabulary) is the XL item** and the highest-unknown. It is not "add gRPC" —
it is making Tamoz's reasoning **observable and interruptible over the wire**: the model client must
surface token/cost deltas mid-call, the graph executor must emit lifecycle events as nodes run, and
both must respect a cancellation that can arrive at any instant. Budget every estimate around this
one item; T1 (transport) and the rest are bounded by comparison. If T2.1 slips, the *forward* loop
still works as a non-streamed request/response (effectively B-lite) — which is a safe fallback
milestone, not a rewrite.

---

## 5. Owner decisions

1. ~~Stream→Tamoz JWT verification-key distribution~~ — **resolved by audit**: the stream's
   capability tokens are opaque HMAC values verified only by its EvidenceTools server; no
   worker-side key exists (T1.3 revised, §0.5).
2. **Canonicalization re-seal migration** shape (T0.1, CONTRACTS §13) — the versioned re-derive across
   the full seal list, not a yes/no. Implemented as MIGRATION_11; the seal list is the audit's
   digest-site map (157 `sha256:` sites; stored rows re-derived, computed sites self-heal).
3. **`SurfaceDescriptor` affirmative approval** (T7.1) — security review + `definition_digest` compat.
4. **Tamoz signing-key custody + rotation** for approval assertions (T7.2, PROTOCOL §10).
5. **Channel-identity → stream-principal binding** for approvals (T7.2, PROTOCOL §5.2).
6. **Relatedness authority default** (T0.3/T5.4) — default *same tenant AND same entity type*
   (adopted for T0.3; widening is explicit config only).
7. **Artifact-retention** budget (T2.3, PROTOCOL §2) — sizing for shadow-replay resolvability.
8. **Contract-package** home — **vendored-and-pinned** in tamoz (`gems/tamoz-stream/contracts/`):
   proto + vectors + decision schema, keyed by a `contract_version` constant; standalone repo
   deferred until schemas stop moving.

---

## 6. What this plan needs from agentic-stream (cross-repo)

| Tamoz phase | Needs from stream (`PLAN_AGENTIC_STREAM_BUILD.md`) | Status (audited 2026-08-12) |
|---|---|---|
| T0.1 | Go-side digest conformance over the shared vectors | ✅ (P0.1; JCS + domain digests in `internal/canonicaljson`) |
| T1.x | Frozen proto (✅) + **executor conformance harness** | ✅ S3 (`internal/executor/conformance/`) |
| T1.x live | **Live pipeline composition** + **worker connection/supervision** | ✅ S1/S2 (`run-live --worker-socket`, budgets, supersession) |
| T2.2 | Stream enforces budgets/cancellation on the streamed events | ✅ S2 (WorkerExecutor budget accounting + watchSupersession) |
| T3 | `EvidenceTools` host over UDS (✅ P1.3) — **opaque HMAC token, not JWT** | ✅ |
| loop | One concrete effector targeting the simulator + simulator ingest | ✅ S4 (`simulated_effector.go`) / ✅ S5 (`SimulatorJSONLReplay`) |
| T5 | Channel B outcome stream live (`outcome.reconciled`) | 🟡 log+cursor done (`internal/notify`); **no SSE endpoint, no outcome emitters** — blocks T5 |
| T6 | RECONSIDER admission (dedup) | ✅ (P5) |
| T7 | Principal registry + approval events (requested/withdrawn/resolved) | 🟡 principals + ed25519 assertion binding exist (`013_governance_interlock.sql`, `policy.go`); **approval events not emitted** — blocks T7 |

---

## 7. Completion bar (owner-confirmed direction, 2026-08-12)

**BAR — "A supervised DIAGNOSE episode runs on the Tamoz side."** The implementation loop (one
phase at a time: plan → review → implement → two sub-agent reviews → fix → commit) stops when ALL
of the following hold and `rake ci` is green under the default locale AND `LC_ALL=C LANG=C`:

| # | Requirement | Phase |
|---|---|---|
| 1 | T0.1: JCS (RFC 8785) + domain-separated `sha256:` digest; all 16 accept + 2 native_only + 8 reject vectors reproduce; re-seal forward migration (MIGRATION_11) re-derives every stored seal with no old-digest tolerance | P1 |
| 2 | T0.2: no path yields `:observed` without an independently-observed reference; regression pins it | P2 |
| 3 | T0.3: situation scopes (MIGRATION_12) + authorize-before-rank | P2 |
| 4 | T0.4: interrupt inside an episode is the typed terminal `interrupt_in_non_interactive_episode`, fails fast | P3 |
| 5 | T0.5: `fast/deep/batch` lane → model tier from config | P2 |
| 6 | T4.1: containment host — allowlist with zero effectful references; dependency-direction test + injection corpus | P3 |
| 7 | T1.1–T1.5: vendored proto + codegen + drift check; handshake (non_interactive:true); opaque-token handling; 4th request origin inbox-keyed on `(episode_id, attempt_id, fence)`; snapshot digest verified before any model call | P4–P5 |
| 8 | T2.1–T2.2: full oneof wire vocabulary in sequence with identity on every event; budget accounting; cancellation | P6 |
| 9 | T2.4: typed Decision to `decision-v1` schema + digest; watch-condition preference at low confidence | P7 |
| 10 | **End-to-end:** a Ruby integration test drives a full DIAGNOSE episode over UDS — stub stream client handshakes, sends EpisodeRequest (snapshot+digest+budget+token), receives the complete in-order event stream, verifies the Decision and exactly one `terminal PRODUCED` | P7 |

**Post-bar (documented, stream-gated, not in the bar):** T2.3 replay ledger + artifact retention;
T3 evidence pull (client exists for the EvidenceTools socket; end-to-end needs the stream host);
T5 learning loop (needs stream Channel B outcome emitters); T6 reconsideration; T7 approval relay
(needs stream approval events); T8 efficiency/evals/retire (incl. the old-engine forward-migration
drop after a retention decision).
