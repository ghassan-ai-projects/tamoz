# P13 scheduler plan review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C9).
Reviewer: fresh-context plan critic (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P13_SCHEDULER_PLAN.md` revision 1 against
`SCHEDULER_DESIGN.md`, INVARIANTS.md 23/25–27/35/38–40, the P13 card,
`durable_runner.rb`, `lease_operations.rb`, `checkpoint_store.rb`, `migrator.rb`.

## Findings and dispositions

| # | Sev | Section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| C1 | High | §4 | Crash seam and dedup location unpinned (either/or); the dedup that makes "exactly once" provable already exists in `CheckpointStore#enqueue_request` | ONE transaction committed (claim→create→enqueue); dedup lives in `enqueue_request`; payload byte-deterministic from occurrence identity + payload_ref (load-bearing, tested) |
| C2 | High | §6 | Invariant-40 intersection enforcement point unspecified | Pinned: intersection at claim time (scheduler vs P8 policy) AND execution time (session-authority binding); in-flight = complete-under-accepted-plan, tested |
| C3 | High | §8/§3 | DST gap/fold named but not specified as tests | Both edge cases named tests with design §8 defaults (gap → skip + `nonexistent_local_time`; fold → earlier instant by default, `both` gated); gap/fold detection contract on fugit |
| C4 | High | §2/§4 | Migration absent | `MIGRATION_2` via the existing Migrator; tables `tamoz_schedules`/`tamoz_occurrences`; safety argument (existing tables untouched; occurrences reference requests by id); pre-P13 DB loads with scheduler disabled |
| C5 | Moderate | — | No typed failure model | Failure-model table reusing CheckpointConflictError/LeaseLostError/ClockRollbackError + typed additions |
| C6 | Moderate | §2/§5 | "Durable circuit seam from P10/P12" is a forward reference to nothing | Seam owned by DR-2; no-second clause extended to circuits |
| C7 | Moderate | §1 | Every proof row is a claim, not a proof | Per-section Proof lines added (tests, not restatements) |
| C8 | Moderate | §7 | Consumer tool surface/approval/delivery unpinned | Consumer surface pinned (scorecard-run tools only, read-only risk class, deterministic read-only approval, ordinary delivery never reported as execution success) |
| C9 | Minor | §2 | fugit not in Gemfile.lock; version deferred (card allows) | Recorded: Gemfile/gemspec change + deterministic-instants contract as the acceptance test for the chosen version |

## Held-out probes

Two pollers claiming one occurrence (fence winner); kill between claim and enqueue
(reclaim + exactly-once); DST fold at 01:30 (earlier instant by default); revocation
mid-flight (complete-under-accepted-plan).

## Status

Corrections integrated in `docs/P13_SCHEDULER_PLAN.md` revision 2. The circuit scope
is owned by DR-2.
