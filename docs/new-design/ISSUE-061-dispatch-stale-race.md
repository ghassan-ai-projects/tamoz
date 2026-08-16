# ISSUE-061 — Episodes on event-dense situations are abandoned `stale_situation` before dispatch (no retry / no re-bind)

- **Status:** FIXED — re-bind on stale (Option 1), committed `275ebe5` in agentic-stream `e2e-test-new-design` (see the fix plan `docs/new-design/ISSUE-061-fix-plan.md` and agentic-stream `docs/design/DECISIONS.md` ADR-013)
- **Repo:** agentic-stream (`e2e-test-new-design`)
- **Detected:** 2026-08-16, Round-3 re-run (water-network M7, live e2e with the smarter-tamoz design)
- **Severity:** medium-high — blocks the recall milestone on event-dense traces and makes continuous-trace deployments fragile; the old engine dispatched the same trace successfully.

---

## One-paragraph summary

When a situation is open and its entity emits events at ≥ ~6 events/minute (the water site-H case had 9 channels/min), the engine creates a new `situation_versions` row per event batch. A trigger evaluation admits an episode bound to version N, but the batch's remaining events (or the next batch) create version N+1 before the runner's dispatch poll picks the item up. The P8 freshness gate (`executor.go`) then refuses dispatch (`bound N, live N+1`) and permanently abandons the episode — **there is no retry and no re-bind to the live version**. The recall milestone (water M7) could not be completed with the shipped traces despite the recall machinery itself being proven live in the aquaculture and greenhouse phases of the same round.

---

## Live symptom (exact evidence)

Every dispatch attempt during the water M7 runs ended identically (9+ runs, various trace freeze points):

```
episodes: epi_… | situation_version 302 | lifecycle_status abandoned | {"bound":302,"live":303,"reason":"stale_situation"}
```

- The trigger DID admit (score 40 ≥ 35): `trigger_evaluations … anomaly_needs_diagnosis outcome=admitted`.
- The episode never reached the worker: `episode_attempts` empty, model endpoint 0 hits, `decisions` empty.
- Reproduced with: the full 5512-line trace, traces cut at 01:19 / 01:18 / 01:17 / 01:16 / 01:15 / 01:14 / 01:13, and traces with the entity's post-trigger events removed entirely (the situation still churned from the admission batch's own remaining events).

The same seam blocks water M6 (RECONSIDER): the correction's provisional version is superseded by the heartbeat-timer's `uncertain` version before the RECONSIDER item dispatches.

---

## Root cause (four interacting mechanisms, all in agentic-stream)

1. **Per-batch situation version churn.** For an open situation, the engine writes a `situation_versions` pair per event batch (provisional → on_time). Water site-H: 4 versions for a single 01:12 minute with 6 events (`situation_versions` 282–287 all at 01:12–01:13, phase `watch` the whole time — no phase change, pure churn). Aquaculture pond-04 (3 channels/min) churned slowly enough that the dispatch won; site-H never did.
2. **Trigger evaluation is mid-batch.** The cognition evaluation runs as events are applied; the admitted item binds the version current at evaluation time, which is not the batch's final version.
3. **The P8 freshness gate is strict and terminal.** `internal/episodes/executor.go` (~lines 165–190): immediately before dispatch it rechecks `SELECT current_version FROM situations`; on any mismatch it marks the episode `abandoned` with `{"reason":"stale_situation","bound":N,"live":N+1}` and does not retry. `internal/episodes/assembler.go:33-42` defines `StaleSituationError`.
4. **Dispatch is a separate poll cycle.** The runner picks admitted items on its own cadence (`--poll-interval`, default 1–2 s), which cannot beat sub-second version churn on dense entities.

The freshness gate's *intent* (never reason over stale facts) is correct; the *mechanism* (abandon without re-bind) turns a race into a permanent loss.

---

## Why it matters

- **Product:** continuous ingestion over dense telemetry is the realistic deployment. Any entity with enough channels will randomly drop episodes — silent, auditable only as `abandoned`/`stale_situation` rows.
- **Round impact:** water M7 (the recall milestone for that domain) could not dispatch; M6 (RECONSIDER) could not materialize. The old engine dispatched the same traces (round-3 water M7 passed on 2026-08-14) — this is a regression in admit→dispatch robustness, likely introduced or exposed by the P8 freshness gate landing after the old round.
- **The capability itself is proven:** cross-entity recall passed live in aquaculture M7 (pond-09→pond-04) and greenhouse M7 (bay-05→bay-03); RECONSIDER downgrade passed live in aquaculture M6. The gap is purely the dispatch/freshness interplay.

---

## Fix options (maintainers' call — not yet dispatched)

| Option | Description | Tradeoffs |
|---|---|---|
| **1. Re-bind on stale (recommended)** | On `live > bound`, re-bind the episode to the live version (fresh snapshot) and retry, bounded (e.g., N attempts or a staleness ceiling). The decision then reflects the freshest state. | Small semantic change: an episode may reason over a slightly newer snapshot than the one that triggered it. Needs a re-assembly path (the assembler already builds the request from the situation version — re-run it for the live version). Most robust for continuous traces. |
| **2. Inline dispatch at admission** | Dispatch the episode in the same engine cycle as the admission (before the batch's remaining events create the next version). | Beats the race by construction for the common case, but couples scheduling to the batch loop; more invasive. |
| **3. Evaluate triggers at batch close** | Run cognition only after the batch's events are fully applied, so the admitted version IS the batch's final version. | Cleanest semantics; changes evaluation timing for every trigger (wider blast radius; re-verify the round-3 moments, which depend on current timing). |
| **4. Accept + document (harness workaround only)** | Keep the gate; regenerate traces so the entity's events end exactly at the trigger moment (the old round's `regen_break.py`/`regenerate_crash.py` pattern). | Zero code risk, but leaves the production behavior fragile — the product still drops episodes on real dense traces. Not a fix. |

**Recommendation:** Option 1 (re-bind on stale, bounded), with Option 3 as the deeper follow-up. Option 1 is surgical: the stale path already computes the live version; re-bind = re-assemble at the live version and re-queue (respecting the one-live-episode-per-situation constraint).

**Acceptance test for any fix:** water M7 scenario — `serve --worker-socket …` with the UNMODIFIED `recurrence.jsonl` must dispatch the site-H episode and produce a decision (currently abandoned every time). Plus `go test ./...` green.

---

## Related

- **ISSUE-060** (fixed): the same serve-restart lifecycle also exposed the non-durable deterministic id sequence (`engine.go:91` `ids.Deterministic()`) → fatal `scheduler_item_id` UNIQUE collisions. Fixed with an idempotent PK-conflict fallback in `cognition/scheduler.go`.
- **ISSUE-062** (fixed): real-model vocabulary enforcement (invalid intent type → repair) + launcher credential resolution.
- **Round context:** the dispatch race and the timer-supersession seam (M6) are the two engine-level findings of the round-3 re-run; both are scheduling/timing, not capability, failures.

---

## Evidence appendix (water-network, 2026-08-16)

- Trace: `~/.my-projects/.e2e-run/round-003-water-network/traces/recurrence.jsonl` (5512 lines, 10 sites).
- Representative run (site-H): trigger `anomaly_needs_diagnosis` admitted score 40.0 at `11:22:51Z`; episode `epi_5CVhRqWSnLsXd_pu` bound 314 → abandoned `{"bound":314,"live":315,"reason":"stale_situation"}`; zero worker requests, zero model calls.
- Version churn at 01:12 (6 events, 4 versions): 282 `on_time`, 283 `provisional`, 284 `on_time`, 285 `provisional`, 286 `on_time`, 287 `provisional` — all phase `watch`.
- The dispatch check: `internal/episodes/executor.go` lines ~165–190 (freshness recheck → `UPDATE episodes SET lifecycle_status='abandoned' … terminal_json '{"reason":"stale_situation",…}'`).
