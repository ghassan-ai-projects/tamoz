# F07 `tamoz-sqlite` — the durable spine is transactionally sound, but effect resolution is unbound to its row scope and the claim window starves control work

Row / queue: F07 (W1A) · baseline `audit-15-09` @ `582ae55` (2026-09-15) · analyst: F07
independent analyst · budget ~55 min (hard cap 60) · read-only.

## Scope and source map

Gem: `gems/tamoz-sqlite`, 70 files, 15120 lines. Entry seam: `Tamoz::SQLite::Adapter`
(`adapter.rb:81-133`) constructs `DatabaseFile` → `Migrator#migrate!` →
`ConnectionPool` → `DatabaseKernel` → `Store`, and every store is a `bind_*`
factory over that one adapter (`adapter.rb:13-79`).

Read in full or in substantive part, with line counts:

| File | Lines | What was read |
|---|---|---|
| `effect_reconciler.rb` | 231 | all — `#resolve`, `#reconcile` |
| `request_inbox_claimer.rb` | 276 | all — candidate window, early-turn deferral, claim CAS |
| `request_inbox_recovery.rb` | 227 | `terminal_fail`, `recover_request_in_transaction`, `ensure_no_earlier_request!` |
| `request_inbox_transitions.rb` | 260 | all — transition plan application, `update_request_transition!` |
| `request_transition_plan.rb` | 83 | all |
| `effect_preparation.rb` | 269 | all — prepare CAS, recovery grants, safety-class branches |
| `effect_completion.rb` | 188 | all — receipt CAS, head CAS, late receipt |
| `effect_lifecycle.rb` | 96 | all |
| `effect_attempt_ledger.rb` | ~78 | `insert!`, `grant_next!` |
| `effect_journal_rows.rb` | 45 | all |
| `effect_record_reader.rb` | 153 | all |
| `effect_journal_key.rb` | 186 | all — identity build + `verify_identity!` |
| `database_kernel.rb` | 112 | all — BEGIN/COMMIT/ROLLBACK, retry |
| `transaction.rb` | 75 | all |
| `connection_pool.rb` | ~145 | all — pragmas, checkout/checkin |
| `lease_operations.rb` | 225 | all — acquire/validate/renew/release |
| `checkpoint_committer.rb` | 249 | all — commit CAS |
| `checkpoint_writer.rb` | 162 | head — guarded facade, `effects` |
| `checkpoint_store.rb` | 247 | facade + `open_writer` |
| `checkpoint_queries.rb` | 233 | `history`, `latest`, `find` |
| `checkpoint_pruner.rb` | ~95 | `prune` |
| `store.rb` | 425 | `each`, `append_version_in_tx` |
| `migrator.rb` | 1526 | migrations 1/9/10/11/12/13/15/16/18/19/20/21/22 + apply/verify path |
| `schedule_store.rb` | 737 | `put_schedule`, `materialize_due`, `acknowledge`, `complete`, `list_occurrences`, `materialize_schedule` |
| `memory_store.rb` | 723 | header contract, `MAX_LIMIT`, index row, search build |
| `comms_store.rb` | 1301 | poller lease, offset, projections, `outbox_rows` |
| `comms_outbox.rb` | 359 | `mark_delivery`, `resolve_delivery`, `milestone_rows` |
| `limits.rb` | ~110 | all |
| `effect_census.rb`, `effect_transition_log.rb`, `thread_deletion_queries.rb`, `request_inbox.rb`, `adapter.rb` | — | read |

## Behavior path

1. **Open.** `Adapter#initialize` (`adapter.rb:81-133`) prepares the file, runs
   `Migrator#migrate!` (`migrator.rb:1394-1412`), verifies `application_id` /
   `user_version` / digest epoch and every ordinal checksum
   (`migrator.rb:1359-1379`), then opens a pool that asserts
   `foreign_keys=1, synchronous=2, journal_mode=wal` before returning a handle
   (`connection_pool.rb:21-52`).
2. **Fence.** `CheckpointStore#open_writer` acquires a lease
   (`lease_operations.rb:8-79`), monotonic `fence = current + 1`, refuses an
   unexpired foreign lease, wraps the block in a `LeaseGuard`
   (`checkpoint_store.rb:85-118`).
3. **Write.** Every mutating operation runs through
   `DatabaseKernel#transaction` with `BEGIN IMMEDIATE` by default
   (`database_kernel.rb:24-67`), which rolls back on any `Exception` and maps
   busy/locked to a bounded retry (`:54-63`).
4. **Commit.** `CheckpointCommitter#append_checkpoint` validates the lease, then
   CASes base-tip, inserts the checkpoint, consumes activations, applies any
   request transition, and advances the head — one transaction
   (`checkpoint_committer.rb:50-156`).
5. **Claim.** `RequestInboxClaimer#claim_next_request` reads a bounded candidate
   window, defers early turns, and CASes `status='queued'` (`request_inbox_claimer.rb:20-27,160-181,235-271`).
6. **Effects.** prepare → start → complete/reconcile, each its own transaction
   (`effect_preparation.rb:72-255`, `effect_lifecycle.rb:21-90`,
   `effect_completion.rb:53-178`, `effect_reconciler.rb:31-225`).

## Lens: correctness

The spine is correct on its normal paths. Commit CAS is a real compare-and-append:
the insert uses the sequence read inside the same transaction and the head advance
carries `lease_owner_id = ? AND lease_fence = ?` with a `changes == 1` check
(`checkpoint_committer.rb:139-155`); `validate_mode!` enforces base-tip equality
for `:advance`/`:turn` (`checkpoint_committer.rb:206-212`). Attempt-level writes
CAS on `attempt_token`, a `UNIQUE` column (`migrator.rb:252`), plus status
(`effect_completion.rb:96-112`). Request claims CAS on `status='queued'`
(`request_inbox_claimer.rb:237-253`).

Two correctness defects are proven below: `F07-SEC-01` (resolution is not bound to
the row's thread/namespace) and `F07-REL-01` (the bounded claim window makes a
valid queued control request unreachable). Both confirmed by probe at this HEAD.

## Lens: security and authority

`F07-SEC-01` reproduces. `EffectReconciler#resolve` loads the effect globally by
key (`effect_reconciler.rb:185`, via the unscoped `EffectJournalRows.effect` at
`effect_journal_rows.rb:10-23`) and updates with
`WHERE effect_key = ? AND status = ?` only (`effect_reconciler.rb:194-206`). It
never compares the row's `thread_id`/`namespace` with `@guard.lease`, and — unlike
`#reconcile`, which calls `validate_lease_in_transaction!`
(`effect_reconciler.rb:86-92`) — it performs **no lease validation at all**. The
row-scope check that exists (`EffectJournalKey.verify_identity!`,
`effect_journal_key.rb:138-179`) is wired into prepare only
(`effect_preparation.rb:139-149`).

`actor` is validated as text and journalled (`effect_reconciler.rb:180,208-222`);
it is audit evidence, not authorization. Probe result at this HEAD: a
`thread.b` writer holding a valid `thread.b` lease resolved a `thread.a` unsafe
effect to `succeeded`, and the returned record still reports `thread_id=thread.a`.

`complete` is not exposed by the same gap: it requires the `UNIQUE` attempt token
(`effect_completion.rb:63,104`; `migrator.rb:252`), which is the designed attempt
fence.

## Lens: reliability and durability

Transaction discipline is strong and uniform. `DatabaseKernel#transaction` wraps
`yield` in `begin/rescue Exception` and rolls back via
`connection.transaction_active?` before re-raising (`database_kernel.rb:34-52`);
the migrator does the same over one `BEGIN EXCLUSIVE` for all pending ordinals
(`migrator.rb:1440-1460`). `PRAGMA synchronous = FULL` with WAL
(`connection_pool.rb:35,40`) is the durable setting. The `ensure` in
`open_writer` releases the guard even when the body raised, chaining the primary
error as `#cause` (`checkpoint_store.rb:98-118`).

The store-level gates named in `documentation/limitations.md` are genuine code
claims, verified:

- **invariant 19 (atomic compare-and-append)** — real: the compare and the append
  are one transaction with a real `UNIQUE (thread_id, namespace, sequence)`
  constraint (`migrator.rb:87`) plus a fenced head advance
  (`checkpoint_committer.rb:139-155`). The limitation is about *evidence* (SIGKILL
  probes), not the mechanism.
- **invariant 20 (single fenced writer)** — the mechanism is real: acquisition
  refuses an unexpired foreign lease (`lease_operations.rb:49-52`), validation
  requires owner + fence + unexpired (`lease_operations.rb:181-186`), and the head
  advance re-checks owner+fence. The limitation again concerns the failing takeover
  *test*, not an absent guard.
- **invariant 18 (versioned allowlisted records)** — `Store` writes a
  `PROTOCOL_VERSION` per version row (`store.rb:219`) and the checkpoint insert
  pins `format_version = 1`, `digest_version = 2`
  (`checkpoint_committer.rb:99`).
- **MIGRATION_15** — present as the `tamoz_artifacts` table with a
  `PRIMARY KEY (tenant_id, digest)` (`migrator.rb:1058-1075`); the limitation is
  the tamper/recovery evidence, and the checksum row is verified on open
  (`migrator.rb:1372-1374`).

## Lens: observability and evidence

Every effect mutation appends an ordered transition inside the same transaction
(`effect_transition_log.rb:28-47`, keyed `(effect_key, transition_index)` —
`migrator.rb:282`), and request transitions are appended alongside their state
change (`request_inbox_transitions.rb:112-122`). `EffectReconciler#resolve`'s
transition records `actor` and the evidence digest (`effect_reconciler.rb:208-222`).

The evidence gap is `F07-SEC-01`'s second half: because resolution carries no
target-scope binding, the transition log records a mutation of thread A's row
attributed only to a caller-supplied actor string, and the returned record still
says `thread_id=thread.a` while the write came through B's writer. The audit trail
is present but does not establish target ownership.

`integ integrity_check` surfaces SQLite's own `PRAGMA integrity_check`,
`foreign_key_check`, and `user_version`, and raises `IntegrityError` unless all
three are clean (`adapter.rb:152-175,216-220`).

## Lens: scalability and resource bounds

Most read paths are bounded: `checkpoint_queries.rb:110` (`LIMIT ?`),
`store.rb:159`, `effect_census.rb:39`, `schedule_store.rb:574,588`,
`comms_outbox.rb:203,305`, `request_inbox_rows.rb:104`. `Limits` bounds pool size,
timeouts, retry count, lease TTL, and attempt TTL with explicit maxima
(`limits.rb:17-27`). The `ConnectionPool` bounds checkout by a monotonic deadline
and raises `BusyError` rather than blocking forever (`connection_pool.rb:89-110`).

Three unbounded reads are real and are recorded as one minor finding
(`F07-BND-02`): `RequestInboxRows#request_history`
(`request_inbox_rows.rb:44-63`, no `LIMIT`), `CommsStore#open_request_refs`
(`comms_store.rb:709-717`, no `LIMIT`), and `CommsStore#conversation_effect_statuses`
/ `request_effect_statuses` (`comms_store.rb:747-774`). Each materializes the full
history for one thread/surface. `F07-REL-01` is the inverse resource defect: the
bound is present but too tight to make progress.

## Lens: maintenance and architecture

The gem is honestly the single implementation of every durable contract, and the
`bind_*` factories state the ownership (`adapter.rb:13-79`). Dependency direction
is correct: it depends on `tamoz-graph`, `tamoz-scheduler`, `tamoz-comms` value
types, never the reverse.

Two contract-fidelity divergences are carried forward by reference, both already
recorded and both re-verified against this source: `CF07-ARCH-01` (the worker
requires `acknowledge_occurrence` / `occurrence_for_request`, which the versioned
`ScheduleStore` contract does not declare — `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:17-75` vs
`schedule_store.rb:487-559`) and `CF07-REL-02` (`complete_occurrence` CASes on
`occurrence_id AND state='running'` only, never on the acknowledged execution id —
`schedule_store.rb:511-535`).

The no-backwards-compatibility directive is **honored**. A gem-wide grep for
`legacy|backward|compat shim|migrate-on-read|read-time toleran|deprecated|old row`
returns only three hits, all benign: two comments stating the no-compat rule
(`migrator.rb:973,1193`) and a clock-rollback message (`lease_operations.rb:221`).
Migrations 13/18/19/20/21 are `DROP TABLE` + `CREATE TABLE` rebuilds with no
`INSERT ... SELECT` carrying old rows forward, and no read path tolerates a
NULL for a column a later migration added.

## Tests and contracts

All run with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`
and one file per command. Every suite below reported **0 failures, 0 errors, 0 skips**.

| Command | Runs | Assertions |
|---|---|---|
| `ruby -Itest test/sqlite_boundary_registry_test.rb` | 5 | 1576 |
| `ruby -Itest test/sqlite_trace_recorder_test.rb` | 11 | 952 |
| `ruby -Itest test/sqlite_schedule_store_test.rb` | 21 | 73 |
| `ruby -Itest test/sqlite_effect_journal_test.rb` | 9 | 37 |
| `ruby -Itest test/sqlite_request_inbox_test.rb` | 8 | 46 |
| `ruby -Itest test/sqlite_stale_request_test.rb` | 26 | 176 |
| `ruby -Itest test/sqlite_store_test.rb` | 6 | 68 |
| `ruby -Itest test/sqlite_checkpoint_test.rb` | 6 | 23 |
| `ruby -Itest test/sqlite_backup_test.rb` | 3 | 16 |
| `ruby -Itest test/sqlite_crash_recovery_test.rb` | 3 | 30 |
| `ruby -Itest test/memory_store_test.rb` | 16 | 112 |
| `ruby -Itest test/sqlite_approval_stores_test.rb` | 10 | 45 |
| `ruby -Itest test/sqlite_deletion_test.rb` | 3 | 19 |
| `ruby -Itest test/sqlite_comms_store_test.rb` | 45 | 246 |
| `ruby -Itest test/sqlite_circuit_store_test.rb` | 11 | 48 |
| `ruby -Itest test/sqlite_kernel_test.rb` | 8 | 63 |
| `ruby -Itest test/sqlite_checkpoint_seams_test.rb` | 7 | 14 |
| `ruby -Itest test/sqlite_boundary_source_audit_test.rb` | 7 | 55 |
| `ruby -Itest test/sqlite_schedule_determinism_test.rb` | 4 | 15 |
| `ruby -Itest test/comms_decision_store_test.rb` | 11 | 26 |
| `ruby -Itest test/effect_identity_test.rb` | 5 | 12 |
| `ruby -Itest test/sqlite_convergence_probe_test.rb` | 5 | 1162 |

**Not run** (reason): `sqlite_raw_oracle_test.rb`, `sqlite_selector_control_test.rb`,
`sqlite_scenario_driver_test.rb`, `sqlite_scenario_registry_test.rb`,
`release_rehearsal_evidence_test.rb`, `release_evaluation_manifest_test.rb`,
`agent_session_effect_test.rb`, `agent_runtime_effects_test.rb` — the first four are
the environment-bound SIGKILL/selector harness the limitations page already marks
unproven; the release/matrix files are slow and belong to other rows; the agent
suites belong to F17/F22. Contract tests touched but owned elsewhere:
`test/scheduler_contract_test.rb` (**not run** — F05 row).

## Findings

---

### F07-SEC-01 — effect resolution accepts a foreign lease and has no row-scope binding

| Field | Assessment |
|---|---|
| Severity | **critical** — a valid writer for one scope marks another scope's ambiguous effect succeeded, producing false completion |
| Confidence | **high** — source trace plus a shared-adapter probe reproduced at `582ae55` |
| Status | **open — still reproduces exactly as recorded** |
| Source evidence | `effect_reconciler.rb:173-206` (no lease validation; `WHERE effect_key = ? AND status = ?` only), `effect_journal_rows.rb:10-23` (unscoped row load), `effect_reconciler.rb:86-92` (the sibling `#reconcile` *does* validate the lease), `effect_journal_key.rb:138-179` (identity check exists but is wired only at `effect_preparation.rb:139-149`) |
| Test/contract evidence | `ruby -Itest test/sqlite_effect_journal_test.rb` → 9 runs / 37 assertions / 0F; `ruby -Itest test/agent_cli_test.rb` uses one thread throughout. No cross-thread rejection test **not found**. Probe: B's lease resolved A's effect, returned record `thread_id=thread.a`. |
| Scanner signal | prior audit - not re-derived. |
| Independent judgment | **Confirmed by direct probe.** Also newly established: `#resolve` is the *only* effect mutation path with neither a lease check nor an attempt-token check — `prepare` (`effect_preparation.rb:74-80`), `start` (`effect_lifecycle.rb:27-33`), `reconcile` (`effect_reconciler.rb:86-92`) and `complete` (`effect_completion.rb:63,104`) all have one of the two. That makes the omission a single-seam gap rather than a broad fencing failure. |
| Root cause | five whys below. |
| Recommendation | see below. |
| Disposition | carried forward open — not re-litigated; independently re-confirmed. |

Five whys: (1) B mutates A because the update predicate is key + current status;
(2) the resolver receives no expected row scope and never compares the row to
`@guard.lease`; (3) the identity verifier that would catch it is wired into prepare
only, and resolve needs no attempt token either; (4) the implementation treats a
globally unique opaque key as sufficient authority to locate *and* mutate;
(5) the mutation contract never required every effect mutation to bind
`(thread_id, namespace)` to the active writer, and the per-thread CLI database
layout hid the shared-adapter case.

Recommendation: at `EffectReconciler#resolve` — the existing seam — validate the
lease inside the transaction as `#reconcile` already does, require the loaded row's
`thread_id`/`namespace` to equal the lease's, and include both columns in the
conditional `UPDATE`, raising the existing `CheckpointConflictError` before
appending a transition. Add the shared-adapter A/B test. No new class, no new
authorization layer.

---

### F07-REL-01 — the eight-row claim window makes a valid queued resume unreachable

| Field | Assessment |
|---|---|
| Severity | **major** — durable liveness failure for an accepted control request |
| Confidence | **high** — source trace plus a probe at this HEAD |
| Status | **open — reproduces, and the threshold is 8, not 9** |
| Source evidence | `request_inbox_claimer.rb:220-231` (`LIMIT 8`), `:160-181` (skips early turns without state change), `:188-190` (`EARLY_TURN_OPERATIONS = %w[turn]`), `:33` (early reason string) |
| Test/contract evidence | `ruby -Itest test/sqlite_stale_request_test.rb` → 26 runs / 176 assertions / 0F; it covers one deferred turn (`:115-149`) but no backlog at the window size. Probe below. |
| Scanner signal | prior audit - not re-derived. |
| Independent judgment | **Confirmed, with a corrected boundary.** The recorded analysis says "nine or more queued turns". My probe finds the starvation starts at **eight**: with exactly 8 deferred turns the `LIMIT 8` window is full, so the resume — although `queued` at `enqueue_sequence=9` — is never returned. At 7 turns the resume claims normally. |
| Root cause | five whys below. |
| Recommendation | see below. |
| Disposition | carried forward open; boundary corrected. |

Probe (`/tmp/f07_probe_c.rb`, temp SQLite under `/tmp`, no repo writes): one paused
thread (1 interrupt), N queued `:turn` requests, then one `:resume`, then three
`run_next` calls.

```
early_turns=1  resume=submitted  run_next=resume
early_turns=7  resume=submitted  run_next=resume
early_turns=8  resume=submitted  run_next=nil
early_turns=9  resume=submitted  run_next=nil
early_turns=12 resume=submitted  run_next=nil
```

Inbox after the 8-turn case, all three `run_next` attempts returning `nil`:

```
["request.start", "turn",   "completed", 0]
["turn.0".."turn.7","turn", "queued",    1..8]
["resume.1",      "resume", "queued",    9]
```

The resume is genuinely queued and permanently unreachable while those eight rows
are unchanged.

Five whys: (1) the valid resume never runs because the claimer never returns it;
(2) the first eight candidates are early turns and the query stops at `LIMIT 8`;
(3) skipping an early turn changes no state, so the next call sees the same eight
rows; (4) the early-turn policy was added with a bounded scan but no fairness
fallback for a control request behind the window; (5) the acceptance tests encode
neither the backlog bound nor the requirement that a valid resume stay reachable —
the root cause is an incomplete claim-query progress contract at the existing seam.

Recommendation: keep the lease, the one-transaction claim, the validator, and the
early-turn deferral. In `claim_request_in_transaction`, when every row in the
window was deferred as an early turn, add the oldest eligible `:resume` for the
open occurrence beyond the window and run it through the same validator and fence.
Merely raising `8` relocates the hole. Add a regression with 8 early turns plus a
valid resume.

---

### F07-INT-01 — a schedule's canonical digest is accepted unverified and survives the SQLite round-trip

| Field | Assessment |
|---|---|
| Severity | **minor** — a content-addressed value can be forged by a public constructor and persisted as durable false provenance |
| Confidence | **high** for the constructor and store behavior; **medium** for operational impact |
| Status | **open — reproduces** |
| Source evidence | `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:69` (`@digest = definition_digest \|\| compute_digest(...)` — presence treated as authority, and not frozen), `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:90` (writes `schedule.definition_digest` straight into the column), `:703` (re-reads it as authoritative with no recomputation) |
| Test/contract evidence | `ruby -Itest test/sqlite_schedule_store_test.rb` → 21 runs / 73 assertions / 0F; `test/scheduler_values_test.rb` asserts only a digest prefix and that field changes change the digest. No wrong-override test **not found**. |
| Scanner signal | prior audit - not re-derived. |
| Independent judgment | **Confirmed by probe.** The SQLite half of this finding is exactly as recorded: the store neither recomputes nor verifies the digest on write or on materialize. |
| Disposition | carried forward open; owned at the scheduler constructor, persisted by this gem. |

Probe (`/tmp/f07_probe_d.rb`):

```
honest=sha256:d7c7dd59b1029f612  forged=sha256:00000000000000000
OVERRIDE_ACCEPTED=true  frozen=false
ROUND_TRIP=sha256:0000000000000000000000000000000000000000000000000000000000000000
FALSE_DIGEST_SURVIVED=true
```

No CLI path was found that can inject the field, so this stays minor; it is not a
current authority bypass.

---

### F07-BND-02 — three comms/inbox read paths are unbounded

| Field | Assessment |
|---|---|
| Severity | **minor** — one thread's or surface's full history is materialized into memory with no limit or pagination |
| Confidence | **high** — direct source read |
| Status | **open** |
| Source evidence | `request_inbox_rows.rb:44-63` (`request_history`, no `LIMIT`), `comms_store.rb:709-717` (`open_request_refs`, no `LIMIT`), `comms_store.rb:747-774` (`conversation_effect_statuses`, `request_effect_statuses`, no `LIMIT`) |
| Test/contract evidence | `ruby -Itest test/sqlite_comms_store_test.rb` → 45 runs / 246 assertions / 0F; no test exercises a large history. |
| Scanner signal | bounds sweep over every `SELECT` in the gem. |
| Independent judgment | Confirmed as unbounded, but impact is bounded in practice: these are per-thread or per-conversation scopes, and the neighbouring reads in the same files *are* limited (`checkpoint_queries.rb:110`, `comms_outbox.rb:203,305`, `comms_requests` history at `HISTORY_LIMIT = 12` — `comms_store.rb:50`). No growth path was shown to be attacker-controlled. |
| Root cause | concise causal: the shared `REQUEST_SELECT` history helper and the two status-count helpers were written for the reading caller's convenience; the bounding convention applied to the sibling projections was not applied to them. |
| Recommendation | Apply the convention already in these files: give `request_history` a `limit:` with the existing `history_limit` bound, and add `LIMIT` to the two comms status helpers (they feed status projections, not full listings). |
| Disposition | record as minor; not a rewrite. |

---

### Findings carried forward by reference (verified against this source, not re-litigated)

| ID | Severity | Status at this HEAD |
|---|---|---|
| `CF04-REL-01` | major | **Still reproduces.** The gem's half is correct: `effect_completion.rb:153-167` moves the head to `reconcile` and retains the late receipt, and `effect_reconciler.rb:188-206` leaves `requires_reconciliation` set for a non-success resolution. The defective selection is `EffectDispatcher#terminal_attempt` (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:280-283`), which always prefers any succeeded attempt. F07 owns the status/attempt state it reads; the fix belongs in the kernel. |
| `occurrence contract and fencing` (`CF07-ARCH-01`, `CF07-REL-02`) | major | **Still reproduces.** `acknowledge_occurrence` records the execution id inside `reason` (`schedule_store.rb:487-505`); `complete_occurrence` CASes `occurrence_id AND state = 'running'` only and never compares the execution id (`schedule_store.rb:511-535`). `materialize_due` still accepts `lease_for:` and never reads it (`schedule_store.rb:168-199`). |
| top-100 005/007/012/019/037/040/041/063/064/087 | — | Prior finding 026 (the `lease_for:` no-op) is the one that lands in this gem and is confirmed above. The others belong to other rows; no new overlap was found. |

## Blind spots

- **`migrator.rb` was read selectively, not line by line.** I read the apply/verify
  path in full (`:1359-1526`), migration 1's full DDL (`:29-339`) as the schema
  base, and migrations 9, 10, 11, 12, 13, 15, 16, 18, 19, 20, 21, 22 in full. I did
  **not** read migrations 2–8, 14, or 17 statement by statement. Those carry the
  memory index, comms prompts/decisions, and the approval tables. A tamper in one
  of those frozen statement lists would be caught by the checksum verification I did
  read (`migrator.rb:1463-1474`), but I did not audit their DDL for constraint
  adequacy.
- **`comms_store.rb` (1301 lines) was read in structure, not in full.** I read the
  poller lease, offset persistence, the projection/cancellation paths, the history
  and effect-status helpers, and the `outbox_rows` bound. I did not read the
  conversation-status projection builders (`:487-650`) line by line, nor
  `comms_store_rows.rb`. Prior finding 006 lives here and I did not independently
  re-derive it.
- **`memory_store.rb` (723 lines)** — I read the header contract, `MAX_LIMIT`, the
  index row, and the search build. I did not verify the retirement/purge path or the
  sensitivity filter end to end. Prior finding 034 lives here and was not
  re-derived.
- **`boundary_registry.rb` (484), `boundary_source_audit.rb` (628),
  `verification_store.rb`, `artifact_store.rb`, `approval_*`, `durable_subscriber_store.rb`,
  `circuit_store.rb`, `thread_tombstone.rb`, `thread_purge.rb`,
  `deletion_report_codec.rb`, `backup.rb`, `checkpoint_wire.rb`,
  `checkpoint_pruner.rb` internals** — not read. `boundary_registry.rb` is prior
  finding 083 (PASS) and I did not re-derive that PASS.
- **No cross-process test was run.** Both reproductions use one in-process adapter
  with two writers. A cross-process or hosted-auth deployment was not exercised, and
  I make no end-to-end graph-unblock claim for `F07-SEC-01`.
- **No load, soak, or large-history measurement was run** for `F07-BND-02`; the
  finding is from source, not from a measured memory profile.
- **The environment-bound gates were not attempted.** `sqlite_raw_oracle_test.rb`
  and `agent_session_kill_matrix_test` need real SIGKILL/SIGTERM delivery, which
  `documentation/limitations.md` records as not completing here. I did not try to
  reproduce or refute the invariant-19/20 or objective-4 evidence claims.
- **Worker/CLI consumers** (`tamoz-agent`, `tamoz-agent-cli`, `tamoz-agent-kernel`)
  were read only where they call into this gem's seams; their own rows own the rest.

## Verdict

**IMPROVE.** Counts: 1 critical, 1 major, 2 minor, 0 info.

Per BAR.md, a row is `IMPROVE` when it has at least one accepted critical/major
finding. `F07-SEC-01` (critical, high, open) and `F07-REL-01` (major, high, open)
both reproduce at `582ae55` under direct probe, and both are accepted.

All six lenses were reviewed. No lens is `not evidenced`: correctness, security,
reliability, observability, scalability, and maintenance each carry source
citations above. The Reliability and Observability lenses rest on the
transaction/fence/transition code I read in full; the parts of reliability that
depend on real signal delivery stay unproven and are recorded in Blind spots rather
than claimed.

Independently challenged items for the coordinator: `F07-REL-01`'s threshold is
**8**, not the recorded 9 — the recorded analysis should be corrected. `F07-SEC-01`
gains a supporting fact: `#resolve` is the sole effect mutation with neither a lease
nor an attempt-token check, which narrows the fix to one seam.
