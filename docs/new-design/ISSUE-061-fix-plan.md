# ISSUE-061 — Fix Plan: Re-bind stale episodes to the live situation version (Option 1)

- **Issue:** `docs/new-design/ISSUE-061-dispatch-stale-race.md` (OPEN)
- **Target repo:** `agentic-stream` (branch `e2e-test-new-design`)
- **Plan date:** 2026-08-16 (rev 2 — revised after two independent plan reviews, see §7)
- **Chosen option:** Option 1 — re-bind on stale, bounded. Deeper follow-up (Option 3, evaluate
  triggers at batch close) is explicitly out of scope for this fix.

---

## 1. The bar (Definition of Done)

A fix is done when ALL of the following are true:

| # | Bar item | How it is proven |
|---|---|---|
| B1 | A stale episode (bound N, live N+k) is **not lost**: the runner re-binds it to the live version, executes it against the live snapshot, and the decision lands — recorded at the live version, with validated intents persisted. | Go test: recording executor observes `request.situation_version == live` and the live snapshot; `episodes.situation_version == live`, `stale_rebind_count == 1`; decision row at live version (validation `accepted`); intents row present. Policy acceptance and command dispatch are the B8 human gate — within a batch the engine runs before the runner, so `current_version` is stable through policy/dispatch (verified `pipeline.go` `runAfterIngest` ordering). |
| B2 | The re-bind is **bounded**: after `maxStaleRebinds` re-binds, a still-stale episode is abandoned durably — not silent, not infinite. | Go test: seeded `stale_rebind_count == max`, live churned further → `lifecycle_status = abandoned`, `terminal_json.reason = stale_situation`, `rebind_attempts` present. |
| B3 | The re-bound request mutates **only** `snapshot`, `situation_version`, `snapshot_digest`. Trigger evidence, delta, reconsideration, executor, budget, tools, identities, and trace context are byte-identical. | Go test: field-level diff between bound and re-bound request JSON (traceparent/tracestate included in the diff). |
| B4 | A live snapshot that fails validation (schema / identity / digest — DB corruption only, engine validates at publish) is **quarantined durably with a distinct reason and never blocks the queue**: episode abandoned `{"reason":"rebind_failed",…}`, counter incremented, pipeline continues. | Go test: mismatched live `snapshot_sha256` vs `snapshot_json` → episode `abandoned`/`rebind_failed`; the runner processes the NEXT admitted episode (queue drains); `serve` is not taken down by it. |
| B5 | No dependency-direction change: the Runner receives the Assembler by injection (`WithAssembler`), no new cross-package imports in `internal/episodes`. | Code review + `go vet`. |
| B6 | The exact water M7 race is reproduced: item created at v1 (mid-batch), v2 published before dispatch, episode admitted bound to v1 → decision produced at v2. | `internal/episodes` test driving the public seam (`cognition.NewEngine` → `Assemble`/`Persist` → `RunOnce` with `WithAssembler`), the `runner_test.go` harness pattern. |
| B7 | Regression gates green: `go test ./...`, `go vet ./...`, `git diff --check`; `make ci-check` attempted with results recorded (lint/style nits are not fix loops per owner directive). | Command output recorded. |
| B8 | The live water-network e2e acceptance (`serve --worker-socket …` + unmodified `recurrence.jsonl` → site-H episode produces a decision whose intents reach policy) is **documented as the final human-run gate**, since the trace is not present on this machine. | Plan §6.5 pins the exact command. |

**Bar for the plan (phase gate):** the plan passes both independent reviews — adversarial gap-search
and completeness — with no blocking findings. Reviews and the disposition of every finding are
recorded in §7. Both agents' verdicts: rev 1 was NOT-READY / INCOMPLETE; rev 2 addresses all
findings (each mapped to a plan section below).

---

## 2. Root cause (verified against code, 2026-08-16)

1. `internal/cognition/engine.go` `Process()` runs per published situation version; `scheduler.Admit`
   creates a `scheduler_items` row bound to `eval.SituationVersion` **at evaluation time**
   (`internal/cognition/scheduler.go` `buildItem`). On event-dense batches the engine publishes
   several versions per batch; the admission is mid-batch.
2. `internal/runtime/pipeline.go` `runAfterIngest` runs the engine batch to completion FIRST, then
   `assemblePending` (binds the episode to the scheduler item's already-stale version), then the
   runner loop.
3. `internal/episodes/executor.go` (~lines 165–190) rechecks `situations.current_version` at
   dispatch; on mismatch it writes `abandoned` + `{"reason":"stale_situation","bound":N,"live":L}`
   inside the same tx. No retry, no re-bind → permanent loss.
4. The freshness gate's intent (never reason over stale facts) is correct; the mechanism
   (abandon without re-bind) turns a race into a loss.

Fix semantics: an episode admitted because of evidence at version N may reason over the **live**
snapshot L > N (the freshest state at dispatch). The triggering evidence (delta) is retained; the
decision is recorded against L. This is exactly the issue's Option 1 trade-off.

---

## 3. Implementation plan (full detail)

### 3.1 Migration — `migrations/028_episode_rebind.sql`

```sql
-- ISSUE-061: re-bind bound episodes to the live situation version at dispatch.
-- NEW column on the existing episodes table (no existing constraint changes),
-- the 024 pattern: plain ADD COLUMN, no rebuild, no FK churn.
ALTER TABLE episodes ADD COLUMN stale_rebind_count INTEGER NOT NULL DEFAULT 0;
```

- Migration machinery (`migrations.go` embedded FS, `storage.go Migrate`) picks it up
  automatically; `storage_test.go` derives `wantVersion` from the last migration (verified), so no
  test pin needs updating.
- `stale_rebind_count` is durable: a re-bound episode that keeps failing across batches and
  restarts cannot loop forever.

### 3.2 `internal/episodes/assembler.go` — new method `Rebind`

```go
// Rebind rebuilds an admitted episode's request for the live situation version.
// The trigger evidence (delta), reconsideration document, identities and trace
// context are preserved; only snapshot, situation_version and snapshot_digest
// change. The live snapshot is validated (schema, identity incl. entity, digest)
// before it can reach a worker; EntityID is re-derived from it.
func (a *Assembler) Rebind(ctx context.Context, tx *sql.Tx, req *Request, liveVersion int) (*Request, error)
```

Steps (all inside the caller's tx):
1. `loadSnapshotJSON(ctx, tx, req.SituationID, liveVersion)` — same helper `Assemble` uses.
2. Unmarshal; `contractsv1.Validate(contractsv1.SchemaSnapshot, snapshot)`; identity check
   (`situation_id`, `tenant_id`, `situation_version == liveVersion`) — mirrors `Assemble`.
3. `entityID, err := snapshotEntityID(rawJSON)`; **assert `entityID == req.EntityID`** — a
   mismatch is data corruption and fails the re-bind (gap review #6).
4. Parse `req.RequestJSON` into a map; set `request["snapshot"]`, `request["situation_version"]`,
   and recompute `request["snapshot_digest"] = canonicaljson.Digest(canonicaljson.DomainSnapshot, snapshot)`.
5. Verify the recomputed digest decodes to the persisted `snapshot_sha256` of the live version
   (same binding `Assemble` enforces).
6. Re-marshal canonically; return a copy of `req` with `SituationVersion`, `SnapshotSHA256`,
   `EntityID`, `RequestJSON` replaced. `EpisodeID`, `AdmissionKey`, `SchedulerItemID`,
   traceparent/tracestate (kept from the bound request — the episode's execution span stays linked
   to the admission trace), and the `reconsideration` document are untouched (B3).

Notes:
- Reconsider items: `reconsideration.correction` is built by the original assembly from
  `delta["correction"]` (the correction document published with the bound version) — historical
  evidence, kept verbatim. The re-bound request deliberately carries TWO frames: the correction at
  version N judged against the live snapshot at L. Documented in §5; no cross-check exists on
  either side (verified: `worker_executor.go` and Ruby `reconsideration.rb` parse independently).
- No new `episode_id` / `admission_key` is generated; the episode row identity is stable.
- The snapshot digest string is decoded to 32 raw bytes by the CALLER for the `snapshot_sha256`
  BLOB column (mirrors `Persist`); §3.3 shows the decode.

### 3.3 `internal/episodes/executor.go` — Runner re-bind gate

1. Add field `assembler *Assembler` to `Runner`; add setter:

```go
// WithAssembler enables the ISSUE-061 re-bind path: an admitted episode whose
// situation advanced past its bound version is re-bound to the live version and
// dispatched instead of abandoned. Without an assembler the runner keeps the
// pre-fix abandon behavior (tests and minimal wiring).
func (r *Runner) WithAssembler(assembler *Assembler) *Runner
```

2. Add `const maxStaleRebinds = 3` beside `maxEpisodeAttempts`.

3. In `RunOnce`, extend the admitted-episode SELECT with `stale_rebind_count` and read it into a
   local. Replace the stale-abandon block:

```go
if liveVersion != int64(req.SituationVersion) {
    if r.assembler != nil && rebindCount < maxStaleRebinds {
        fresh, rebindErr := r.assembler.Rebind(ctx, tx, &req, int(liveVersion))
        if rebindErr != nil {
            // Quarantine durably (same tx) with a distinct reason: the episode
            // is always the OLDEST admitted row (ORDER BY accepted_at LIMIT 1),
            // so returning an error would stall every batch and stop serve.
            // The counter still increments so the bounded path is reachable.
            terminal, _ := json.Marshal(map[string]any{
                "reason": "rebind_failed", "bound": req.SituationVersion,
                "live": liveVersion, "error": rebindErr.Error(),
                "rebind_attempts": rebindCount + 1})
            _, _ = tx.ExecContext(ctx, `
                UPDATE episodes SET lifecycle_status = 'abandoned', ended_at = ?,
                    terminal_json = ?, stale_rebind_count = stale_rebind_count + 1
                WHERE episode_id = ?`,
                r.clk.Now().UTC().Format(time.RFC3339Nano), terminal, episodeID)
            if r.telemetry != nil {
                r.telemetry.ObserveStaleRejection()
            }
            return nil // committed skip; the batch continues past it
        }
        req = *fresh
        snapshotHash, err := canonicaljson.DecodeDigest(req.SnapshotSHA256)
        if err != nil {
            return fmt.Errorf("decode re-bound snapshot digest: %w", err) // cannot happen; digest was just verified
        }
        if _, err := tx.ExecContext(ctx, `
            UPDATE episodes
            SET situation_version = ?, snapshot_sha256 = ?, request_json = ?,
                stale_rebind_count = stale_rebind_count + 1
            WHERE episode_id = ?`,
            req.SituationVersion, snapshotHash, req.RequestJSON, episodeID); err != nil {
            return fmt.Errorf("persist episode re-bind: %w", err)
        }
        if r.telemetry != nil {
            r.telemetry.ObserveStaleRebind()
        }
        // Fall through to dispatch: bound == live inside this tx (writes are
        // serialized), so the freshness intent holds for the dispatched request.
    } else {
        // existing abandon path; terminal_json now includes the rebind count:
        // {"reason":"stale_situation","bound":N,"live":L,"rebind_attempts":count}
        // unchanged mechanics + ObserveStaleRejection (as today).
    }
}
```

4. The `stale` skip-bookkeeping stays for the abandon paths only; after a successful re-bind the
   code continues to `StartAttempt` as for a fresh dispatch.

Rationale for re-bind+dispatch in ONE tx: the freshness gate's guarantee ("never reason over stale
facts") is preserved — `_txlock=immediate` + WAL serializes the runner's tx against the engine
writer (verified: the engine's `situation_versions` INSERT is committed in its own tx), so the
version the episode is re-bound to is the version it dispatches against. A post-dispatch churn is
a NEW admission-cycle race, handled by the next scheduler item, not by this episode.

### 3.4 `internal/telemetry/runtime.go` — `ObserveStaleRebind`

Mirror `ObserveStaleRejection` (atomic counter `staleRebinds`, exported as
`agentic_stream_stale_rebinds_total` in the metrics snapshot). Recoveries become visible; the
existing rejection counter keeps counting true losses (bound exhausted, rebind_failed). Verified:
no test pins the exact metric key set (`p8_latency_test.go` reads per-key; handler test uses
`strings.Contains`).

### 3.5 `internal/runtime/pipeline.go` — wiring

Hoist the assembler to a local and inject it:

```go
assembler := episodes.NewAssembler(cfg.Spec, cfg.IDGenerator).WithCostControl(&costcontrol.Controller{})
runner := episodes.NewRunnerWithEpoch(...).WithAssembler(assembler).WithCostControl(...)...
```

Production pipelines always get the re-bind path. No behavior flag. Verified callers: `serve` and
`run-live` both wire via `runtime.NewPipeline` (`cmd/agentic-stream/main.go`); `internal/replay`
never constructs a Runner (assembler only) — no other wiring changes.

### 3.6 Tests

**Fixture (rev 2 — replaces the "seedFreshnessEpisode shape" claim):** the existing
`seedFreshnessEpisode` writes `snapshot_json = '{}'` and a zero digest — unusable for the
re-bind path, which validates schema + digest. New helper `seedRebindEpisode` writes:

- a **real** snapshot document per `schemas/v1/snapshot-v1.json` (required: `situation_id`,
  `situation_version`, `situation_type`, `tenant_id`, `entity{type,id}`, `phase`, `severity`,
  `completeness`, `event_horizon` RFC3339, `spec_digest ^sha256:[0-9a-f]{64}$`, `facts`;
  `additionalProperties:false` — no extra keys),
- `snapshot_sha256 = canonicaljson.Digest(canonicaljson.DomainSnapshot, doc)` decoded to 32 bytes,
  in BOTH `situation_versions` rows (bound v1 + live v2, distinct documents) and the `episodes`
  row (bound digest),
- the bound request_json carrying the v1 document as `snapshot`, with `situation_version: 1`.

**`internal/episodes/rebind_test.go`** (external `episodes_test`):
- `TestStaleEpisodeRebindsToLiveVersionAndDispatches` (B1): runner `.WithAssembler(asm)` +
  recording executor asserts request snapshot is the LIVE doc and `situation_version == 2`;
  episodes row (`situation_version == 2`, `stale_rebind_count == 1`); decision row at
  `situation_version == 2`; intents reach `accepted` (policy evaluated in the same batch).
- `TestRebindOnlyMutatesSnapshotFields` (B3): field-level JSON diff (incl. traceparent/tracestate)
  between bound and re-bound request.
- `TestRebindLimitExhaustedAbandons` (B2): seed `stale_rebind_count = 3` (the value of
  `maxStaleRebinds`; the constant is unexported and this test is external — the literal is pinned
  with a comment) + live churned → `abandoned` with `rebind_attempts` in terminal_json.
- `TestRebindFailsClosedOnCorruptLiveSnapshot` (B4): live `situation_versions.snapshot_sha256`
  does not match its `snapshot_json` → episode `abandoned`/`rebind_failed`, counter incremented;
  a SECOND admitted episode is then processed (queue drains, no stall).
- `TestRebindWithoutAssemblerKeepsAbandonGate`: runner without `WithAssembler` on stale →
  abandoned (documents the seam). This is covered by the pre-existing
  `TestP8DispatchRefusesStaleSituation` (`p8_freshness_test.go`, runner built without
  `WithAssembler` → `stale_situation` abandon), so no new test is added.
- `TestRebindRaceReproducesWaterM7` (B6): `runner_test.go` harness pattern —
  `cognition.NewEngine` + `Process(v1)` (item bound to v1) → publish v2 → `Assemble`/`Persist`
  (episode bound v1) → `RunOnce` with assembler → decision at v2.

**`internal/telemetry`** — extend `p8_latency_test.go` with one `ObserveStaleRebind` assertion.

**`p8_freshness_test.go`** — `TestP8DispatchRefusesStaleSituation` remains valid unchanged
(runner without assembler still abandons); the deadline/kill tests are untouched. Verified: no
test anywhere pins the string `stale_situation` or the exact metric set.

### 3.7 Docs

- **ADR-013** appended to `docs/design/DECISIONS.md` (after ADR-012): "Re-bind stale episodes to
  the live situation version before dispatch". Records the invariant-5 carve-out: an episode is
  bound to ONE immutable snapshot at any instant; the re-bind re-points it once (bounded,
  pre-dispatch, durable counter) to the live version. Finite budget, identity, and admission
  evidence are unchanged. Invariant 10 (explainability) is served by `stale_rebind_count` +
  `terminal_json` (stale_situation with rebind_attempts, or rebind_failed).
- `docs/new-design/ISSUE-061-dispatch-stale-race.md` → Status: FIXED (after commit), pointer to
  this plan and the commit SHA.
- This plan stays as the fix record (§7 = review disposition).

---

## 4. Out of scope (explicit)

- Option 3 (evaluate triggers at batch close) — deeper follow-up, changes evaluation timing for
  every trigger; would require re-verifying round-3 moments.
- Option 2 (inline dispatch at admission) — couples scheduling to the batch loop.
- Any worker/Ruby (`tamoz`) change — the worker consumes the request as-is; the re-bound request
  is the same wire shape.
- `scheduler_items.situation_version` is NOT rewritten (the item stays bound to the trigger's
  version; only the episode row is re-bound). The FK chain item→evaluation→version stays intact.
- No change to the policy/dispatcher freshness gates — they remain the version-freshness authority
  for intents/commands after the episode terminates (gap review #2; safe within a batch because
  the engine runs before the runner, verified `runAfterIngest` ordering).

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Re-bound episode reasons over a snapshot newer than the trigger's — semantic drift | Accepted by the issue's Option 1 recommendation; delta retained so the triggering evidence is still in the request. |
| Unbounded re-bind on an entity that churns faster than dispatch | Durable `stale_rebind_count` + `maxStaleRebinds = 3`; then abandon with audit record. |
| Corrupt live snapshot reaches the worker, or stalls the pipeline | B4: validate schema/identity/entity/digest in `Rebind`; on failure QUARANTINE durably (`rebind_failed`, counter incremented) — never an error return, because the episode is always the oldest admitted row and an error would stall every batch and stop `serve` (gap review #1, BLOCKING — fixed in rev 2). |
| Reconsider items (M6): the persisted correction (version N) becomes inconsistent with the live snapshot (L) | Accepted, documented semantic frame: "correction N judged against live L". The correction document is kept verbatim (B3). Re-verify the round-3 aquaculture M6 downgrade proof under this frame as part of B8 (gap review #5). |
| Triggers firing during the re-bound dispatch are coalesced (one live episode per situation) | Accepted and documented (gap review #4): pre-fix, dense-trace episodes were abandoned 100% (loss of everything); post-fix, only triggers firing during the bounded model-call window are coalesced — a strict improvement. B8 notes this; the coalesced items remain explainable (invariant 10). |
| Double-counting delta events in the live snapshot | The worker sees snapshot (live state) + delta (trigger evidence); the decision is recorded at the live version — the same frame the round-3 aquaculture/greenhouse M7 proofs used. |
| Entity drift between bound and live snapshot | `Rebind` asserts `liveSnapshot.entity.id == req.EntityID`; a mismatch fails the re-bind (→ `rebind_failed` quarantine). Impossible by construction (situation→entity is 1:1); defended anyway (gap review #6). |

## 6. Verification sequence

1. Targeted: `go test ./internal/episodes/... ./internal/runtime/... ./internal/telemetry/...`
2. Full: `go test ./...` and `go vet ./...`
3. `git diff --check`
4. `make ci-check` attempted (includes tidy/build/vet/lint-ci/test-short/deadcode/vulncheck);
   results recorded. Style-only lint findings are recorded, not fix-looped (owner directive).
5. **Human gate (B8, not runnable here):** trace absent from this machine. Exact command:
   `AGENTIC_STREAM_SUBSCRIBER_TOKEN=<token> bin/agentic-stream serve --db <db> --spec <water.situation.yaml> --trace ~/.my-projects/.e2e-run/round-003-water-network/traces/recurrence.jsonl --trace-format simulator --worker-socket <tamoz.sock> --worker-ca <ca> --worker-cert <cert> --worker-key <key> --worker-server-name <name> --listen 127.0.0.1:8080 --poll-interval 1s`
   (flags per `cmd/agentic-stream/main.go` serve; the worker topology from
   `E2E_INTEGRATION_RUNBOOK_ROUND3.md` §0 F-3/F-8). Pass = site-H episode dispatches and its
   decision's intents reach policy (previously `abandoned stale_situation` every run).

## 7. Plan review disposition (phase-gate record)

**Rev 1 reviewed by two independent agents — verdicts: NOT-READY (gap-search), INCOMPLETE (completeness).**
Every finding is addressed in rev 2:

| # | Finding (agent) | Severity | Disposition (rev 2) |
|---|---|---|---|
| G1 | Fail-closed re-bind error permanently stalls the batch + stops `serve`; counter never increments | BLOCKING | §3.3: quarantine durably with `rebind_failed` + counter increment; never an error return. B4 rewritten. |
| G2 | Policy/dispatcher freshness gates still refuse intents/commands after churn | SHOULD-FIX | Accepted as the ongoing freshness authority; safe within a batch (verified ordering). B1/B8 strengthened to the full decision→intent→command chain. |
| G3 | `seedFreshnessEpisode`'s `{}` snapshot + zero digest fails Rebind validation | SHOULD-FIX | §3.6: new `seedRebindEpisode` fixture with real doc + real digest (schema fields enumerated). |
| G4 | Dense-trace coalescing during dispatch is undocumented | SHOULD-FIX | §5: accepted and documented; B8 notes it. |
| G5 | RECONSIDER: correction N vs live L frame is inconsistent, unverified | SHOULD-FIX | §5 + §3.2: documented frame; re-verify M6 in B8. |
| G6 | EntityID parsed pre-rebind, never recomputed | NIT | §3.2 step 3: re-derive + assert equality. |
| G7 | Trace context handling unspecified | NIT | §3.2: kept from bound request; B3 diff includes trace fields. |
| G8 | `decodedSnapshotHash` undefined | NIT | §3.3: `canonicaljson.DecodeDigest(fresh.SnapshotSHA256)`, mirrors `Persist`. |
| C1 | `decodedSnapshotHash` undefined | compile-blocking | Same as G8. |
| C2 | Fixture unusable | real | Same as G3. |
| C3 | EntityID not re-derived | real | Same as G6. |
| C4 | Design invariant 5 deviation unaddressed | real | §3.7: ADR-013 with invariant-5 carve-out. |
| C5 | `make ci-check` missing from gates | real | §6.4 added (attempted; results recorded). |
| C6 | `maxStaleRebinds` unexported vs external test package | real | §3.6: pin literal 3 with comment. |
| C7 | B4 serve failure mode contradicts code | real | Resolved by G1's quarantine design (no batch abort). |
| C8 | B6 test package mismatch (`pipeline_test.go` is `runtime_test`) | real | §3.6: B6 moved to external `episodes_test` using the public `runner_test.go` harness. |
| C9 | Exact serve command unspecified | real | §6.5: full command pinned. |

Verified safe by the reviewers (no change needed): migration ordinal 028; `storage_test.go`
wantVersion derivation; all episodes INSERT column lists (DEFAULT 0 covers); FK integrity for the
re-bound version (`decisions`/`intents` reference an existing version); one-tx serialization
(`_txlock=immediate`); no `stale_situation` string pins; telemetry metric set not pinned; replay
and serve need no other wiring; no re-reservation of cost needed.
