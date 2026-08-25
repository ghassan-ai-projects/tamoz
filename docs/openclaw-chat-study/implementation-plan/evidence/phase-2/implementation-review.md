# Phase 2 implementation review

Status: **implemented and reviewed** — three waves plus two repair passes, all
committed on `feature/openclaw-chat-study-refresh`: milestone projection
`6426f4f` (2a), surface rendering + callback ack `5b6df96` (2b), visible
cancellation + reconnect view `16606bd` (2c), review repairs `2e12af9`, and
the straggler-completion commit `94d73e2`. All evidence is
fixture/scripted-transport plumbing evidence; no live Telegram or real-provider
behavior is claimed.

## Scope delivered

- **Milestone projection from committed facts** — claim, recovery,
  effect-wait, and phase-commit facts project through `Worker#notify_sink`
  onto journaled=0 control rows carrying the request reference, per-request
  sequence, phase, and both lifecycle axes. Emissions sit after the durable
  commit of each fact; no polling loop, no speculation.
- **Bounding and coalescing** — one live pending row per request reference is
  updated in place; past a bound of 32 rows further milestones are dropped.
  Delivered rows are immutable (their bytes stay what the receipt recorded).
  Milestone scans filter request_ref in SQL (`json_extract`), not after LIMIT.
- **Per-surface rendering** — Telegram: first milestone sends a card;
  successors are durable `edit_message` effects behind `DeliveryDrainer`,
  bound to the card's receipt message id (while the card is pending,
  coalescing keeps one row). CLI JSON: envelopes carry both lifecycle axes
  populated from milestone markup. CLI human mode renders attached-turn
  stream events; unattended milestone facts surface through the reconnect
  view — the initially-added TTY renderer had no live producer and was
  removed rather than faked (review finding, resolved by reclassification).
- **Visible cancellation** — durable timeline via MIGRATION_21:
  `requested` stamped inside the enqueue transaction, `observed` where the
  turn runner consumes the cancel redirect, terminal derived from the settle
  kind recorded at completion. A raced completion reads "completed before the
  cancellation took effect"; failed/blocked settles read their own words; a
  cancellation never claims an issued external call stopped (invariant 9).
- **Reconnectable status view** — `tamoz comms request R<ref>` answers task/
  delivery axes, queue facts, and the cancellation timeline from SQLite alone;
  identity round-trip and monotonic sequences pinned; stream-resume-from-
  sequence does not exist and is recorded as a named limitation.
- **Callback acknowledgement** — callback queries are acknowledged immediately
  after durable admission recording and before any turn processing; ack-then-
  crash ordering proven both ways, prompt activation + decision durable across
  a worker restart boundary.

## Review loop

Early read-only review (correctness/liveness/boundedness) over 2a → verdict
NEEDS FIXES (3 minors): delivered-row mutation, stale-thread /cancel,
unbounded pairing state — all repaired (`2e12af9`) with the SQL exact-filter
folded in. Final-round lens reviews then covered phases 2–3; their Phase 2
findings (terminal wording keyed to the reservation axis instead of the task
axis — HIGH; duplicate-disposition guard for control commands) were repaired
in the final correctness pass. The test-quality lens drove the renderer
reclassification and black-box worker observation tests.

## Verification

Focused suites at final state (one file per command):
`test/progress_projection_test.rb` 12/360 · `test/cancellation_visibility_test.rb`
11/98 · `test/callback_ack_crash_test.rb` 2/20 · `test/comms_gateway_test.rb`
33/190 · `test/sqlite_comms_store_test.rb` 42/219 · `test/reconnection_resume_protocol_test.rb`
1/18 · `test/delivery_drainer_test.rb` 10/50 · `test/agent_worker_test.rb`
24/114 · `test/sqlite_approval_stores_test.rb` 10/45 (schema pin 21).

Slow-lane receipts: recorded at the closure revision in this file's
Verification addendum — both locales of `rake ci_full` green after the schema-
oracle pin was reconciled to version 21 and the requirements manifest gained
its MIG-21 row (machine-regenerated artifacts).

Enola: baseline sha256 e017dfa… pinned pre-work; closure check reported only
ordinary call-edge additions.

## Bar status

| Bar item | Status | Evidence or blocker |
| --- | --- | --- |
| Project lifecycle milestones | Complete | ladder/coalesce/bound/history-exclusion suite + real-worker emission tests |
| Bound and coalesce progress | Complete | ≤32 stress with delivered-row immutability map; SQL exact-filter |
| Render per surface | Complete (CLI TTY reclassified) | Telegram card+receipt-bound edits end-to-end; JSON axes; attached-stream contract stated in code; unattended facts via reconnect view |
| Visible cancellation | Complete | same-txn stamping, consume-point observation, raced wording pinned incl. refute /stopped/i on completed-before-effect; failed/blocked words tested |
| Reconnectable CLI view | Complete | store-only answers after every writer gone; typed unknown/malformed refusals; JSON document schema pinned |
| Callback + crash coverage | Complete | ack ordering both ways; restart-durable activation/decision |

## Provenance and blind spots

- Source revisions: `6426f4f`, `5b6df96`, `16606bd`, `2e12af9`, `94d73e2`,
  `ff062da`; trees clean at each commit except the disclosed straggler window
  (94d73e2 landed hunks that three wave commits missed because agents flush
  final writes after reporting; receipts bind to ≥ `94d73e2`).
- All evidence fixture-based (scripted transports, deterministic scripted
  models, SQLite). No live Telegram, no real provider; usefulness remains the
  benchmark's claim. The B0 harness scores C8 (visible cancellation) and the
  full nine-scenario ladder deterministically offline.
- Blind spots: observed-cancellation stamps land where owned code consumes the
  redirect — the engine can consume inline inside resume, so observed-before-
  settle is not expressible offline (C8 records it as typed edge
  `engine_observed_before_settle`); aggregate /status exposes only the newest
  live request's cancellation timeline; milestone sequences are monotonic per
  process and prune at occurrence close (not globally durable); capacity
  refusal of a milestone drops silently by design ("a projection failure is
  dropped, never fatal").
