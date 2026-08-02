# P14 stream plan review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C10).
Reviewer: fresh-context plan critic (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P14_STREAM_PLAN.md` revision 1 against
`STREAMING_INPUT_DESIGN.md`, INVARIANTS.md 44–51, the P14 card, and the
effect-journal/request-inbox/lease machinery.

## Findings and dispositions

| # | Sev | Section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| C1 | High | §5/§8/§12 | Virtual-time machinery does not exist; byte-determinism is a claim; sqlite `backend_time`/`guard_backend_clock!` interaction undefined | Injected `StreamClock` contract; stream tables never call wall `backend_time`; replay = re-executing the identical operator chain under the virtual clock; golden-trace determinism test (run twice, diff bytes) |
| C2 | High | §7 | Command journaling through "the ordinary effect boundary" unimplementable: `EffectJournal#prepare` requires the active graph execution; no graph run holds a lease at stream dispatch | Command dispatch IS the episode-run terminal node (journal's active-execution precondition holds); no separate stream-side journaling path |
| C3 | High | §2/§5 | Transaction seam not named; adapter `transaction` is non-reentrant; outbox→inbox drain unspecified | `process_partition` is the single transaction boundary; drain outside it via `enqueue_request` idempotency (stable request id; drained-twice = no-op); crash semantics named |
| C4 | High | §3 | Simulated-source authentication seam has no production contract; a fixture key that always validates proves nothing | Production `ChannelConnector`/`SourceSession` contract; fixture implements it; wrong key/forged identity/replayed credential → durable rejection cases |
| C5 | High | §8 | "Asserted at data-flow level" has no mechanism; shadow mode's model credentials unaddressed | Credential kinds enumerated; per-mode resolution rules; poison-resolver behavioral test + constructor-absence type assertion |
| C6 | Medium | §7 | Interlock proof mechanism unspecified; delivery-window TOCTOU unaddressed | Read-only `InterlockReader` + dependency-direction test; interlock re-read at the narrowest point + simulator-side ready assertion; hard-failure "dispatched while interlock tripped" |
| C7 | Medium | §6 | One-episode-per-Situation not enforced at the graph layer | Namespace = Situation id (graph's single-fenced-writer rule enforces it); request id within `Wire::MAX_REQUEST_ID_BYTES` |
| C8 | Medium | §2 | Migration path unspecified | Same database via the existing Migrator (P11 precedent); never reinterprets old bytes |
| C9 | Medium | §8/§12 | No typed failure taxonomy | Reuses LeaseLostError/CheckpointConflictError/ClockRollbackError + InterlockUnavailableError (fail closed), WatermarkRegressionError, QuarantineOverflowError |
| C10 | Medium | §9/§12 | DoD misses the probes; protected-scenario isolation has no mechanism | Sequence-case (good-then-corrupt same id) + outbox-drain cases added; protected scenarios structurally separated; card-clause "physical" kept verbatim + deferred |

## Held-out probes

Same-id corrupt payload after a good one (quarantine record); superseded Decision in
the adversarial window (post-final-revalidation → delivery); replay worker holding a
credential (poison resolver); idle partition freezing watermarks (idle timer advances
under virtual time); outbox drained twice after crash (one logical episode).

## Status

Corrections integrated in `docs/P14_STREAM_PLAN.md` revision 2. The card clause
"physical" is kept verbatim with the simulated-source contract making the real-adapter
swap safe (never silent).
