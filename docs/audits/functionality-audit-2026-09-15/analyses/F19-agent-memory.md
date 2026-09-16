# F19 `tamoz-agent-memory` — admission and retrieval are sound; deletion receipts overclaim and no retention pass exists

Row / queue / baseline: F19 / W4A / `audit-15-09` @ `582ae55`, 2026-09-15 / analyst `analyst_f19` / budget 45 min (hard cap 60)

## Scope and source map

Real files read, with line counts:

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-agent-memory/lib/tamoz/agent_memory.rb` | 31 | gem entry; require order |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb` | 478 | gates (a)/(b)/(c), reject matrix, `AdmissionResult` |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/record.rb` | 353 | immutable versioned `MemoryRecord`, codec shape |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/surface.rb` | 139 | `Engine`, namespace, index projection, codec |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/retrieval.rb` | 206 | authorize-then-rank recall, budget, drops |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/lifecycle.rb` | 253 | correct / supersede / quarantine / **delete** / purge, receipt |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb` | 326 | deterministic gates + one journalled model call |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb` | 145 | holdout/human-gated promotion |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/behavior_transition.rb` | 172 | transition value, snapshot digest, prompt-surface digest |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/transition_registry.rb` | 376 | record / claim / finalize / release_or_finalize |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/situation_recaller.rb` | 198 | observed-episode projection for the stream boundary |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/verified_outcome_reference.rb` | 104 | T5.3 authenticated `:observed` reference |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/errors.rb` | 45 | typed failure family incl. `MemoryDeletionError#receipt` |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/limits.rb` | 39 | bounded budget table |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/version.rb` | 9 | version |
| `gems/tamoz-agent-memory/tamoz-agent-memory.gemspec` | 16 | deps: kernel, core, sqlite, tools |

Store implementation cited by name (row F07's file, read as this gem's store): `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb` (723 lines). Supporting reads: `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb:65-243` (`append_in_transaction`, `append_version_in_tx`), `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:894-912,1025-1075`, `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:45,114-131,146-152`, `gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb:1-129`, `gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:406-420,565-589`, `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:33-118`, `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb:114-152`, `gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:50-115`.

**Entry seam**: `Tamoz::Agent::Memory::Engine.new(tenant:, adapter:)` (`surface.rb:55`) is constructed once per worker session at `worker_runtime.rb:897`, gated on the operator's `sources.memory.enabled` flag read from the runtime directory *outside the workspace* (`runtime_directory.rb:118-131,45`).

## Behavior path

**Admission.** Three gates reach the one private `admit` (`admission.rb:242`).
Gate (a) `admit_episode` (`admission.rb:77`) → size pre-check (`:79`) → optional anti-self-ingestion mark (`:90`) → `episode_epistemic_kind` (`:374`) which calls `VerifiedOutcomeReference.reason` (`verified_outcome_reference.rb:44`) → `admit`.
Gate (b) `admit_owner_request` (`:103`) → `owner_request_negatives` (`:169`) → `build_owner_request_record` (`:185`) → optional `contradiction_check` → `admit`.
Gate (c) `admit_consolidation_candidate` (`:134`) → layer/state/shape/gate-set checks → `admit`.

`admit` runs, in order: duplicate-identity probe on `repository.current_version` (`:245`); `reject_reason` matrix (`:286`); `store_rejected` (`:255`) for a rejection; else `record.with(state: :active, transition: …)` + `append` (`:259-267`). `append` (`:443`) writes record + index row in one transaction through `MemoryStore#append` (`memory_store.rb:118-160`).

**Retrieval.** `Retrieval#recall` (`retrieval.rb:55`) → `repository.search` (`memory_store.rb:203`) which binds caller authority as SQL parameters and filters namespace/state/tenant/user/project/sensitivity≤caller/compatibility/validity/situation **before** any row is materialized (`authorized_scan_body`, `memory_store.rb:410`) → materialize (`retrieval.rb:94`) → deterministic `rank` (`:107`) → `apply_budget` (`:139`) → `mark_recalled` (`:172`) → trace events.

**Lifecycle.** `delete` (`lifecycle.rb:77`) locates the head by `LIKE '%/<memory_id>'` (`:120-147`), appends a `:deleted` version at `version+1` (`:81-88`), then builds a receipt from `deletion_sinks` (`:96-97`). `purge` (`:105`) delegates to `MemoryStore#purge` (`memory_store.rb:305`), which requires `h.deleted = 1 OR i.state = 'deleted'` **and** an expired retention window.

**Consolidation.** `consolidate` (`consolidation.rb:26`) → `evaluate_gates` (`:82`) → `consumed?` (`:126`) → `store_preimage` (`:136`) → `bounded_model_call` (`:181`) → `validate_proposal!` (`:243`) → `mark_consumed` (`:148`) → `admission.admit_consolidation_candidate`.

**Behavior transitions.** `Wisdom#promote` (`wisdom.rb:35`) → `TransitionRegistry#record` (`transition_registry.rb:58`) at the provider/eval boundary; the intake side is `SessionMemory#claim_behavior_transition` (`session_memory.rb:25`) at first thread intake and `SessionMemory#finalize_behavior_claim` (`:74`) after the deliberation commits.

## Lens: correctness

Admission default-reject is real and durable. `reject_reason` (`admission.rb:286-316`) returns a reason for oversized, secret-shaped, speculation-as-fact (`:289-293`, requires `:observed` plus a hedge word or trailing `?`), missing provenance (`:294`, waived for `:prescribed`), recalled-as-new (`:297`), empty tenant scope (`:300`), empty owner (`:303`), nil sensitivity (`:306`), and policy-instruction-from-untrusted (`:309-313`). Each rejected candidate is persisted as a `:rejected` version carrying `rejection_reason` (`:274-284`, `:255`); `test_admission_reject_matrix_is_durable_and_never_raises` reads it back through `repository.version` (`test/memory_engine_test.rb:365-375`).

`verified_outcome_reference.rb:44-67` refuses a *claimed* reference that fails any of: the nine required fields (`:49`), a non-learnable verdict (`:54`), a foreign episode/attempt (`:57`), or a failing/raising verifier (`:61`, `:72-76`). Only `:observed`.

Retrieval correctness and scoping are verified empirically, not just read: a probe admitted records for `alice/p1`, `bob/p2`, and `alice/p2` in one tenant and recalled on `terms: ["secret"]`. `alice/p1` returned `["alice"]` with `project == "p1"`, `alice/p2` returned `[]`, `bob/p2` returned `["bob"]`. No cross-user or cross-project leak. `valid_until_ms` is a SQL predicate (`memory_store.rb:427`) and the head-join `h.current_version = i.record_version AND h.deleted = 0` (`:416-419`) means a superseded/corrected version leaves active recall immediately — confirmed by `test_correction_removes_bad_record_from_active_recall_and_index` (`test/memory_engine_test.rb:548-561`).

Deletion as *active-recall exclusion* is correct: after `lifecycle.delete`, recall returned `[]` (probe). What deletion does **not** do is correct — see `F19-SEC-01` and `F19-DEL-01`.

## Lens: security and authority

**Injection boundary — verified sound on all three gates.** The untrusted entities that could seed memory are the stream event source, the workspace file, the MCP reply, and the tool result; none of them reaches `admit` unlabelled.

- *Gate (a)*: `:observed` requires the authenticated reconciled-outcome reference. The bare `independently_observed` boolean has no power — a truthy boolean and a truthy string both admit as `:reported` (`test/memory_engine_test.rb:193-222`). The production stream verifier is `->(reference) { reference.fetch("source_authority") == event.source }` (`live_learning_handlers.rb:93`), and `reason` refuses a raising verifier rather than propagating it (`verified_outcome_reference.rb:72-76`).
- *Gate (b)*: `owner_request_negatives` (`admission.rb:169-181`) refuses `:observed`, refuses `layer: :wisdom`, refuses a `:constraint` whose statement matches `/approv|allowed_tools|permission/i`, refuses secret-shaped statements, and requires `authority.to_s == "owner"` (`:176`).
- *Gate (c)*: `epistemic_kind == :observed` is refused (`admission.rb:148`) and `source_refs` must be non-empty (`:154`); `deterministic_gates` additionally refuses `candidate.recalled?` as taint (`consolidation.rb:117`) and requires ≥2 distinct source identities (`:109`).

**Retrieval authority**: all caller fields are SQL binds (`memory_store.rb:203-256`), and the restricted-existence signal shares the same single-sourced `authorized_scan_body` (`memory_store.rb:410-431`), so it cannot become an existence oracle — this is the prior 034 fix, and it holds.

**Authority is not widened by content**: the engine only advertises `enabled/tenant/owner` (`worker_runtime.rb:909-913`) and nothing in the memory path touches the profile or capability surface. `SituationRecaller#validate_caller!` (`situation_recaller.rb:43-56`) pins the caller to `user/project = "stream"` and the engine tenant, refusing anything else.

**Deletion is the gap** — `F19-SEC-01`.

## Lens: reliability and durability

The consolidation model call is correctly journalled: `bounded_model_call` (`consolidation.rb:194-210`) routes through `EffectDispatcher.run(operation: "memory.consolidate", safety: :unsafe, logical_key: consolidation_logical_key(...))` with a deterministic key over owner + canonical scopes digest + candidate digest + prompt digest (`:219-222`). There is no raw `model.generate` outside that block (`:203` is inside the dispatcher block). `consolidate` refuses to proceed without a durable context (`:34-37`). This satisfies the AGENTS.md effect rule — **no FX violation**.

Preimage-before-rewrite holds: `store_preimage` returns the entry version (`:136-146`) and `mark_consumed` CASes against it (`:148-154`), fixing the dead-success-path defect; `validate_proposal!` re-reads and verifies the preimage (`:270-273`).

Recovery is **not wired** — `F19-REL-01`.

## Lens: observability and evidence

Recall and drops emit correlated trace events (`retrieval.rb:177-202`): `:memory_recalled` carries `memory_id`, `record_version`, `layer`, `classification`, `authorized`; `:memory_dropped` carries `memory_id` and `reason`. `RecallResult#matched_restricted_ids` and `#dropped_ids` (`:31-44`) are returned, not buried.

Admission rejection carries `reason` on the result (`admission.rb:42-50`). The stream logs the admitted `memory_id` and `epistemic_kind` (`live_learning_handlers.rb:111-114`).

The observability gap is that the two negative outcomes on the session path are silently discarded: `SessionMemory#record_episode_memory` rescues `StandardError` to `nil` (`session_memory.rb:92-93`) and `claim_behavior_transition`/`finalize_behavior_claim` rescue the claim conflict to `nil` (`:36-37`, `:79-80`). An operator sees a completed thread and cannot tell whether the episode was remembered. See `F19-OBS-01`.

## Lens: scalability and resource bounds

Bounds are declared and mostly enforced: `max_statement_bytes` 4096 (`limits.rb:12`) enforced in the record validator (`record.rb:256`), in `reject_reason` (`admission.rb:287`), and in `build_statement` (`:420`); `max_source_refs` 16 (`record.rb:262`); `max_lexical_hits` 200 (`retrieval.rb:56`); `retrieval_token_budget` 1024 with lowest-first drops (`retrieval.rb:139-166`); `max_injected_knowledge` 8 (`:141`); `max_consolidation_candidates` 8 (`consolidation.rb:27`); `MAX_QUERY_TERMS` 32 (`retrieval.rb:22,88`); the searchable projection is the first 512 bytes (`surface.rb:133`). `SituationRecaller` caps at 64 records / 32 KiB with 8× overfetch clamped to 512 (`situation_recaller.rb:11-14,36`).

**Unbounded growth is the gap** — `F19-DEL-01`.

## Lens: maintenance and architecture

Dependency direction is honest: the gemspec declares kernel/core/sqlite/tools (`tamoz-agent-memory.gemspec:12-17`), and `agent_memory.rb:5-6` states the gem reaches up into nothing. `Surface#index_for` (`surface.rb:103-125`) keeps storage layout out of the record class, so `record.rb` has no SQL. The `IndexRow` value stays in `tamoz-sqlite`; `Retrieval#materialize` reads string-keyed rows (`retrieval.rb:96`), which is the deferred 034 STATE item — still deferred, still consistent, no new drift.

Prior 089's minor `[SIZE]` is properly resolved: `OwnerRequest` (`admission.rb:55-58`) threads one value into `owner_request_negatives` and `build_owner_request_record`, ending the parallel keyword lists.

One honesty defect: `transition_registry.rb:306-313` carries a `FINDING (not fixed here …)` note on `cas_control`'s ignored `expected`, and `cas_control` compares against a re-read version (`:316-323`) while both callers (`:88`, `:197`, `:240`) already hold a `control` from `read_control`. The window is wider than the caller's read, so a concurrent writer between read and CAS is silently clobbered rather than raising. `F19-REL-02`.

## Tests and contracts

All run with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`, one file per command, from `/Users/ghassan/my-projects/tamoz`.

| Command | Result |
|---|---|
| `ruby -Itest test/memory_engine_test.rb` | 26 runs / 164 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/memory_store_test.rb` | 16 runs / 112 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/memory_treatment_profile_test.rb` | 14 runs / 218 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/memory_repository_adapter_test.rb` | 10 runs / 104 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/memory_session_integration_test.rb` | 4 runs / 24 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/improvement_candidate_test.rb` | 14 runs / 284 assertions / 0 failures / 0 errors / 0 skips |
| `ruby -Itest test/stream_episode_skills_memory_test.rb` | 12 runs / 49 assertions / 0 failures / 0 errors / 0 skips |

`ls test/ | grep memory` also lists `stream_learning_loop_test.rb` and `stream_invariants_test.rb`, which exercise admission from the stream boundary; **not run** (time budget — the seven files above already cover every lens, and both touch the stream gem's row rather than F19 alone).

**Not found**: no test asserts that a deletion receipt's `removed` counts correspond to anything existing, and no test asserts that `derived_consolidations` excludes the record's own rows. `test_deletion_emits_receipt_and_propagates_to_index` (`test/memory_engine_test.rb:562-573`) asserts only `primary_record == 1` and `index_rows >= 1`. `test_delete_tombstones_the_store_then_purge_removes_ciphertext_after_retention` (`:766-791`) exercises the purge but not the tombstone precondition — it passes `now:` past the boundary, and the pre-boundary refusal it asserts comes from `StoreError`, not from a tombstone check.

**Not run**: `rake ci` / `rake ci_full` (excluded by the brief).

Probes (in `/tmp`, zero repo scratch files): `/tmp/f19_probe_delete.rb`, `/tmp/f19_probe2.rb`, plus two inline `ruby -e` probes for derived-record survival and scope isolation.

## Findings

### F19-SEC-01 — the deletion receipt overclaims: `removed` names sinks that were not removed, and one sink counts the record's own rows

- **Severity**: `major`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: `lifecycle.rb:96-97` builds the receipt from `deletion_sinks` (`:201-218`), which returns a literal `removed: {"primary_record" => 1, "index_rows" => index_rows, "derived_consolidations" => derived, ...}`. Only the `:deleted` version append happened (`:88`). `derived_references` (`:235-249`) counts `tamoz_store_versions` rows where `CAST(v.payload AS TEXT) LIKE '%<memory_id>%'` — which includes the deleted record's own v1 and v2 payloads, since both embed the `memory_id` they are keyed by. Nothing in `delete` writes to, or even identifies, a derived record. `BAR.md:70-73` makes materially misleading evidence a `critical`/`major` matter; the invariant-54 receipt is consumed as deletion proof (`documentation/design/memory.md`, "Deletion and correction propagate … with a deletion receipt naming what was removed").
- **Test/contract evidence**: `test_deletion_emits_receipt_and_propagates_to_index` (`test/memory_engine_test.rb:562-573`) asserts only `primary_record == 1` and `index_rows >= 1`, so a fabricated `derived_consolidations` passes. Probe (`/tmp/f19_probe_delete.rb`, `/tmp/f19_probe2.rb`, inline probe 3): one admitted record, no derived records in the store, `delete` returned `"removed" => {"primary_record"=>1, "index_rows"=>2, "derived_consolidations"=>2, ...}`. `COUNT(*) … LIKE '%<memory_id>%'` was **1 before** the delete and **2 after** — the sink counted the tombstone versions it had just written. In a fourth probe a genuine derived record citing the deleted `memory_id` was appended; the receipt then reported `derived_consolidations => 3`, and `engine.store.get(namespace, "knowledge/mem.derived-1")` returned the derived record **still present and unchanged** after the delete.
- **Scanner signal**: none — found by reading `deletion_sinks` against `derived_references` and confirmed by probe.
- **Independent judgment**: the *active-recall* exclusion half of deletion is confirmed correct (recall returns `[]` after delete; the head-join in `authorized_scan_body` excludes the tombstone). The *evidence* half is not. I confirmed the overclaim is not a counting nuance: an `agent-deleted` record's derived row survives untouched while the receipt says it was removed. I could not establish that any production caller consumes `derived_consolidations` to make a decision (no caller of `lifecycle.delete` exists outside tests — see `F19-DEL-01`), so the misleading evidence is currently latent rather than acted upon; that bounds the severity at `major` rather than `critical`.
- **Root cause (five whys)**:
  1. Why does the receipt say derived consolidations were removed when they were not? Because `deletion_sinks` reports them as `removed` unconditionally.
  2. Why unconditionally? Because `delete` performs no derived-record step, so the value is a descriptor of the sinks the design *names*, not of the work the method *did*.
  3. Why is a descriptor passed off as a result? Because `derived_references` returns a `COUNT(*)` used as a quantity in the same hash as `primary_record` and `index_rows`, which are genuine post-hoc measurements — the mix makes an intent list read as an outcome list.
  4. Why was that not caught? Because the only assertion on the receipt checks two keys that happen to be honest, and the documented invariant-54 shape names four sinks without requiring each to be verified.
  5. Why does the contract allow it? Because the deletion path has no definition of "this sink was handled" separable from "this sink was considered" — the receipt has no `skipped`/`not_applicable` vocabulary, so a sink the design lists must be reported as removed to keep the shape. The preventing contract is: a receipt field is either measured after the operation or absent.
- **Recommendation**: at the existing `deletion_sinks` seam (`lifecycle.rb:201`), report a derived or cached row in `removed` only when this call removed or rekeyed it, and otherwise move it to `pending` (the receipt already has that list and `MemoryDeletionError` already consumes it at `:93`). Fix the LIKE self-match by excluding the deleted key's own versions from the count. Do not add a deletion engine.
- **Disposition**: open, pending coordinator disposition. Recommend independent challenge, since the probe used a synthetic derived record rather than the consolidation pipeline.

### F19-DEL-01 — nothing in production deletes a memory, and no retention pass exists, so memory grows without bound

- **Severity**: `major`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: `grep -rn "lifecycle\.\|purge_expired"` over `gems/`, `apps/`, `bin/` returns **no caller** of `engine.lifecycle` and no caller of `MemoryStore#purge_expired` (`memory_store.rb:377`) — the only repo-wide hit outside the definition is `coverage/index.html`. The purge pass that would bound the store exists and is unreachable. `MemoryStore#append` hardcodes `deleted: false` (`memory_store.rb:133`), so even after `lifecycle.delete` the store head keeps `deleted = 0` (probe: `store_head.deleted=0`, `current_version=2`, `CIPHERTEXT_LIVE_VERSIONS=2` after a successful delete), and `expired_tombstones` (`:511`) only picks up heads with `h.deleted = 1`. `purge` requires `h.deleted = 1 OR i.state = 'deleted'` (`:311-328`), so the only route that would still work is the agent-deleted branch of the tombstone query (`:517-519`) — and its sole entry point is the unreachable `purge_expired`.
- **Test/contract evidence**: `test_delete_tombstones_the_store_then_purge_removes_ciphertext_after_retention` (`test/memory_engine_test.rb:766-791`) is titled for the tombstone but never asserts it; it calls `purge` with an explicit future `now:` and asserts `purge.fetch("removed").any?`. Because `purge` also accepts `i.state = 'deleted'`, the test passes on a store head that is *not* tombstoned — the test name overstates what it proves. **not found**: no test asserts `store.head_version` / `deleted = 1` after `Lifecycle#delete`.
- **Scanner signal**: none — found by call-graph search for the lifecycle and purge entry points.
- **Independent judgment**: confirmed by probe that after `lifecycle.delete` the deleted statement remains retrievable: `engine.repository.version(namespace, "knowledge", mid, 2)` returned `"Recall probe statement"` in the clear, and the probe asserted the `tamoz_store_heads` row still has `deleted=0`. Record versions are append-only (`record.rb:11`) with no compaction (`supersede` at `lifecycle.rb:47` appends; `correct` at `:23` appends), so per-memory bytes strictly increase with corrections, and `retention_default_seconds` (`limits.rb:20`) is read nowhere. Whether the operator-facing `tamoz` CLI is *supposed* to expose a purge command is beyond this row; what is verifiable here is that the gem ships a purge pass with no caller.
- **Root cause (five whys)**:
  1. Why does deleted memory persist indefinitely? Because no production code path calls `purge` or `purge_expired`.
  2. Why does nothing call them? Because `Lifecycle#purge` is not exposed through the `Engine`'s consumers — `worker_runtime.rb:894-913` builds the engine and reads only `tenant`, and the gem's public surface ends at the engine; the maintenance pass the comment calls "the tamoz-agent maintenance pass" (`lifecycle.rb:100-101`) was never scheduled.
  3. Why is that not visible as a defect? Because the tests drive `purge` directly on the engine, so the suite proves the mechanism works and never notices that nothing invokes it.
  4. Why does the retention bound not apply anyway? Because `MemoryStore#append` hardcodes `deleted: false` (`memory_store.rb:133`), so the store head is never tombstoned by the agent-deleted path, and `expired_tombstones` gates on `h.deleted = 1`.
  5. Why is the invariant not enforced? Because invariant 31 ("deletion propagates with proof") is stated as a property of the *operations*, not of the *system*: no test or contract asserts that a deleted record's bytes are unreachable after the retention window in a running worker. The preventing contract is a retention assertion at the worker level, not another purge method.
- **Recommendation**: the smallest credible action is to schedule the pass that already exists — invoke `MemoryStore#purge_expired` from the worker's existing maintenance/sweep seam (the same place the toolbox's stale-staging sweep runs) rather than adding machinery. Separately, make `ActivityDelete` tombstone the head so the `h.deleted = 1` branch becomes reachable; `append` already accepts a `deleted:` keyword (`store.rb:65`) and `IndexRow#state` already carries `deleted`, so this is one flag at the `lifecycle.rb:156` seam, not a new path.
- **Disposition**: open. Recommend the coordinator confirm ownership of the maintenance pass with whoever owns `worker_runtime.rb` before recording a fix, since the missing caller may live outside this gem's row.

### F19-REL-01 — the crash-recovery path for behavior transitions is unreachable, so a crash between claim and finalize wedges the registry

- **Severity**: `major`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: `TransitionRegistry#release_or_finalize` (`transition_registry.rb:230-243`) — the method whose comment describes "Crash recovery (DR-1 C1/C2)" — has no production caller. Repo-wide grep returns only `test/memory_engine_test.rb:866,879`. The production shape is: `SessionMemory#claim_behavior_transition` (`session_memory.rb:25-38`) sets the row `:recorded → :claimed`; `SessionMemory#finalize_behavior_claim` (`:74-82`) sets it `:activated` and is called from `SessionDeliberation#deliberate` (`session_deliberation.rb:32`). A crash after the claim but before the deliberation commits leaves `:claimed` with a claimant and `pending_transition_id` still set. `record` refuses any new transition while a pending id exists (`transition_registry.rb:70`), and `Wisdom#assert_no_pending_promotion!` refuses too (`wisdom.rb:90-99`), so the guard *is* necessary — but `release_or_finalize` is never invoked to clear it.
- **Test/contract evidence**: `test_behavior_transition_serialized_pending_and_release_rules` (`test/memory_engine_test.rb:845-884`) exercises `release_or_finalize` directly with both `session_references` lambdas and both outcomes. It proves the method correct and proves nothing about it being wired. **not found**: no integration test drives a crash between claim and finalize through `Session`.
- **Scanner signal**: none — found by call-graph search.
- **Independent judgment**: the *same-owner take-over* escape at `transition_registry.rb:154-159` is real and softens this — a retry by the same `intake:<thread_id>` owner returns the claimed row, so a retrying worker recovers. Confirmed by reading. But that path requires the same thread to be re-driven; a thread that is abandoned (operator never resumes it) leaves the registry pending forever and blocks every future promotion. `agent-memory` does not own the worker's thread lifecycle, so I cannot prove from this row whether abandonment is reachable — that is why confidence is `high` on "no caller exists" and the operational cost is stated rather than asserted.
- **Root cause (five whys)**:
  1. Why can the registry wedge? Because nothing clears a claimed-but-uncommitted transition.
  2. Why not? Because `release_or_finalize` has no caller.
  3. Why was it written then not wired? Because the claim/apply/finalize protocol was built against the storage contract and tested at that boundary, while the worker's startup/recovery seam was never updated to consult it.
  4. Why did the tests not catch it? Because they call the method directly, which is the natural way to test a durable protocol and the reason the missing caller is invisible.
  5. Why is the gap structural? Because ownership of "who recovers a claimed transition" is split: the registry owns the operation, `tamoz-agent-session` owns the thread lifecycle, and neither row's contract names the other. The preventing contract is a recovery call at the worker's existing start-of-intake seam.
- **Recommendation**: at the existing first-intake seam (`session_bindings.rb:23`, immediately before `claim_behavior_transition`), call `release_or_finalize` for the observed `pending_transition_id` with a `session_references` lambda that already exists in the session-store reader. Do not add a recovery daemon.
- **Disposition**: open. Recommend the coordinator route to the `tamoz-agent-session` row, since the missing caller is at that boundary and F19 can only prove the gem side.

### F19-OBS-01 — every negative admission outcome on the session path is swallowed, so an operator cannot see a memory that was not written

- **Severity**: `minor`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: `SessionMemory#record_episode_memory` (`session_memory.rb:84-93`) rescues `StandardError` to `nil` around `@configuration.memory.admission.admit_episode` (`:88-91`). The 089 fix made a failed durable write visible through `AdmissionResult#stored?` (`admission.rb:42-50`, `457-462`), but the only caller of `record_episode_memory` (`session_lifecycle.rb:48`) ignores the return value, and `stored?` is read **nowhere in production** — repo-wide grep finds it only at `admission.rb:49` (the definition) and `test/memory_engine_test.rb:379,384`. A rejected admission is equally invisible: `admit_episode` returns the `AdmissionResult` (`admission.rb:239,256,268`) and it is discarded. `claim_behavior_transition` (`:36-37`) and `finalize_behavior_claim` (`:79-80`) likewise rescue the claim conflict to `nil`.
- **Test/contract evidence**: `test_rejected_storage_failure_is_reported_through_stored_flag` (`test/memory_engine_test.rb:377-385`) drives a real append failure by closing the adapter and asserts `refute result.stored?`. It proves the gem reports the loss; it cannot prove anyone consumes the report. **not found**: no test asserts that a session-path admission failure produces any observable record.
- **Scanner signal**: prior top-100 089 (`docs/audits/top100-audit-2026-09-11/089-admission.md`) is the direct antecedent of this seam.
- **Independent judgment**: this is *not* a re-litigation of 089. 089's defect — `store_rejected` swallowing to `nil` under a comment claiming operator visibility — is fixed and I re-verified it: `store_rejected` returns a boolean (`admission.rb:457-462`), the rejection paths thread it into `stored?` (`:239`, `:255-256`), and the doc comment now matches the code (`:36-41`, `:452-456`). The residual is one layer out, in the session gem: the value now exists and has no consumer. Because `record_episode_memory` is best-effort by design (memory must not fail a turn), swallowing is defensible; what is not defensible is that a rejection and a storage failure are then indistinguishable from success to every operator surface. The severity is `minor` because the turn's correctness is unaffected and `memory_summary` (`worker_runtime.rb:908-913`) already exposes on/off state.
- **Root cause**: 089 fixed the reporting obligation at the producing seam and stopped there; no consumer was required to read it, and the best-effort rescue in `session_memory.rb:92` makes the producer's report the end of the line. Concise: a signal with no consumer is not observability.
- **Recommendation**: at the existing `session_memory.rb:92` rescue, log the `AdmissionResult#reason` and `#stored?` through the logger the session already holds, and count them on the existing memory-summary projection. No new signal catalog entries.
- **Disposition**: open. Coordinator should note this as the carried-forward residual of 089, not a new defect in `admission.rb`.

### F19-REL-02 — `cas_control` ignores its `expected` argument, widening the control-record CAS window

- **Severity**: `minor`
- **Confidence**: `medium`
- **Status**: `open`
- **Source evidence**: `transition_registry.rb:316-323` takes `expected` and re-reads `head_version` itself, comparing against the re-read value rather than the control the caller validated. The file's own comment (`:306-313`) records this as a known, deliberately unfixed finding and argues the single-writer discipline may make it safe. Both kinds of caller — `record` (`:88`), `finalize` (`:197`), `release_or_finalize` (`:240`) — pass a `control` they read earlier and then re-read inside, so the "check the pending id I validated, then CAS that same version" guarantee the comments promise is not what executes.
- **Test/contract evidence**: `test_behavior_transition_serialized_pending_and_release_rules` (`test/memory_engine_test.rb:845-884`) proves the serialization under a single writer; **not found**: no concurrent-writer test for the control record.
- **Scanner signal**: the in-source `FINDING` comment at `transition_registry.rb:306`.
- **Independent judgment**: I confirmed the argument is ignored and that callers hold a prior read. I could not construct a reachable interleaving, because constructing one requires two concurrent promotion pipelines, which the single-pending guard and the operator-driven promotion path make hard to reach from this row. Recorded as `medium` for that reason, per BAR.md's rule that an unprovable chain must not claim higher confidence. Note this is the accepted prior 034 `[STATE]` item's neighbourhood but a different seam: 034 STATE was `IndexRow` degradation in the store, which I re-verified is unchanged and consistent.
- **Root cause**: the compare-and-swap was written against the store's version rather than the caller's snapshot, so the validated precondition and the CAS are not the same read.
- **Recommendation**: pass the caller's `expected` through to `if_version:` and delete the re-read, so the fail-closed behaviour the surrounding comments claim is the behaviour that runs. Smallest change at the existing private seam.
- **Disposition**: open, `medium` confidence. Recommend independent challenge or deferral to the concurrency row, since the reachability question is not answerable from F19.

## Blind spots

- **`purge_expired` was not executed.** I verified by call-graph search that it has no production caller and read its selection logic, but I did not run the batch pass, so whether its `still_pending` list is well-formed on a real tombstone set is a lead, not a finding.
- **The `tamoz-agent-session` recovery wiring is read, not driven.** `F19-REL-01` rests on a repo-wide grep for `release_or_finalize` and on reading `session_bindings.rb:23` / `session_deliberation.rb:32`. If a recovery call exists behind a dynamic dispatch or an eval surface, I did not find it; I searched for the method name only.
- **The consolidation pipeline has no production caller either.** `grep` for `.consolidate(` outside the gem returned nothing, so gate (c) `admit_consolidation_candidate` is reachable only from `Consolidation#consolidate`, which only the tests call. I did not raise this as a separate finding because, unlike the retention pass, no source comment claims a scheduled maintenance caller for it; it belongs with `F19-DEL-01`'s ownership question for whoever owns the background sweep.
- **`stream_learning_loop_test.rb` and `stream_invariants_test.rb` were not run** (time budget). Their admission assertions overlap the stream gem's row more than F19's.
- **`tamoz-evals-runner`'s `MemoryRepositoryAdapter`** (`memory_repository_adapter.rb:70`) builds a second engine over the same store; I read its construction line and did not trace its treatment paths. `test/memory_repository_adapter_test.rb` passed, but that is the adapter's contract, not this gem's.
- **Deletion of sensitive records was not probed.** My probes used `:internal` records with no protection codec configured, so I verified no decryption and no ciphertext handling on the delete path.

## Verdict

**IMPROVE** — 0 critical, 3 major (`F19-SEC-01`, `F19-DEL-01`, `F19-REL-01`), 2 minor (`F19-OBS-01`, `F19-REL-02`), 0 info.

All six lenses reviewed. Correctness, security/authority, reliability/durability, observability/evidence, scalability/resource bounds, and maintenance/architecture each have `file:line` evidence above; none is `not evidenced`. The bar is met by three accepted major findings.

Two properties are worth stating plainly because they are the ones this row was asked to test and they hold: **admission cannot be steered by untrusted content** on any of the three gates, and **the consolidation model call is journalled through `EffectDispatcher.run`** with no raw call inside a node. Retention and receipt accuracy are where this gem falls short.
