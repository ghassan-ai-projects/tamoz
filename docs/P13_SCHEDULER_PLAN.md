# P13 — durable scheduling: implementation plan

Status: accepted for implementation (revision 3 — checkpoint deep-review transaction,
migration, and proof-baseline corrections integrated; see
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Authoritative inputs: `docs/design-v0.1/SCHEDULER_DESIGN.md` (source of truth for
semantics), `AGENT_DESIGN.md` §15, invariants 38–40 plus 23, 25–27, 35, the P13 card in
`docs/PROJECT_HANDOVER_PLAN.md`. `fugit` behavior/version is re-checked at
implementation time (the card requires it; this plan pins the contract, not the version).

Phase activation rule: committed as a design artifact while P10 is active; the handover
ledger's P13 row stays `pending` until P12 closes. No P13 code before that.

## 1. Scope commitment and phase outcome

Handover card outcome, verbatim: "optional `tamoz-scheduler` deterministically
materializes one recurring read-only product task into the ordinary durable request
inbox exactly once per logical occurrence."

| Outcome clause | Work package | Proof (test, not claim) |
|---|---|---|
| package/store contract, values, revisions | P13-D | `Schedule`/`Occurrence` values per design §3/§5; immutable content-addressed revisions with CAS; strict `at`/interval/cron; IANA timezone + DST with the §8 edge cases as named tests; deterministic jitter from occurrence id |
| SQLite store, CAS/fence, due scan, atomic identity | P13-A | adapter per design §11 capabilities; `materialize_due` atomically claims + creates occurrence + enqueues request under one fence/transaction; dedup uses the CheckpointStore enqueue primitive; payload byte-deterministic from occurrence identity + payload_ref |
| bounded misfire/overlap/concurrency/backlog, reclaim, pause/disable/delete/cancel, separate statuses | P13-B | design §6/§7/§10 semantics as named tests: each misfire policy, each overlap policy, bounded backlog, reclaim with higher fence, tombstone delete, separate delivery/execution statuses |
| grants intersect current policy; plan/review every occurrence; headless approval denies/escalates; narrow self-management | P13-C | enforcement point pinned (claim-time AND execution-time intersection, below); every occurrence drafts + reviews a plan (asserted); headless deny/escalate; in-flight revocation semantics pinned + tested |
| one safe product consumer | P13-P | the recurring READ-ONLY scorecard-summary consumer with pinned tool surface, risk class, approval/delivery policy; kill-at-seam proof with zero duplicate logical turns |
| reference-calendar/fake-clock suite | P13-E | design §12 suite incl. the two DST edge cases as named tests with expected values |

Hard zero (fail the phase regardless of value): duplicate logical turn, authority
widening, fabricated approval, false-green task success. Every due occurrence has exactly
one durable reason.

## 2. Package boundary and reuse

New gem `tamoz-scheduler` (design §2) with ONE responsibility: durably materialize due
occurrences into the existing request inbox. It does NOT execute agent logic, approve
actions, retry arbitrary effects, deliver results, or keep correctness in process timers.

- depends on `tamoz-core` contracts + a schedule store; `fugit` for strict cron + IANA
  timezones (adding fugit touches the workspace Gemfile and the gemspec — recorded; the
  deterministic-instants contract in §5/§8 is the acceptance test for the chosen
  version, C9); natural-language schedule parsing is never accepted into the durable
  record.
- publishes a versioned structural `ScheduleStore` contract; `tamoz-sqlite` implements
  the first store in an explicitly required optional module.
- Tamoz Agent owns payloads, grants, approval destinations, delivery, user-facing policy.
- Reuse: the request inbox + graph lease/fence from P6/P7 (`DurableRunner`,
  `CheckpointStore#enqueue_request`, `LeaseOperations`); the P8 profile policy for grant
  intersection; the P9 skill snapshot digests for payload references; the durable
  circuit record from DR-2 (`docs/DR2_DURABLE_CIRCUIT_PLAN.md`, scheduler scope) for
  consecutive-failure circuits (one record type, four scopes). The occurrence
  lease/fence is the EXISTING lease/fence pattern applied to the new scheduler tables,
  not a new mechanism.
- **No second engine clauses, extended:** no second workflow engine, no second lease
  machinery, no second circuit engine (C6). The poller loop is an interchangeable
  process per design §1, not an engine.

## 3. Values and revision rules (P13-D)

`Schedule` carries the design §3 fields verbatim (id, revision, owner, enabled, kind,
expression, timezone, start_at, end_at, misfire_policy, misfire_limit, overlap_policy,
max_concurrency, jitter_window, payload_ref, thread_policy, capability_grant,
behavior_version, approval_policy, delivery_policy, budgets, created_by, created_at,
definition_digest). Payload and policy artifacts are immutable and content-addressed;
editing creates a new revision with CAS and never mutates a definition an occurrence
already used.

`Occurrence` identity derives from `(schedule_id, schedule_revision, nominal_fire_at_utc)`
(design §5); its `request_id` is a deterministic digest of that identity. Jitter changes
`not_before`, never the identity or nominal instant. Manual runs use a caller-supplied
request id and do not consume/move the natural occurrence.

Kinds: `at` (≤ 1 logical occurrence), `interval` (elapsed-time from explicit anchor),
`cron` (strict expression + required IANA timezone). No calendar/event-stream/
filesystem-watcher/natural-language/trigger-script kinds in v1. The CLI shows the next
five instants, timezone, DST behavior, and DOM/DOW semantics before approval; host-local
timezone is never an implicit durable default (invariant 39).

Proof: value/validation matrix; revision CAS test; identity determinism test (jitter
changes `not_before` only); CLI preview test.

## 4. Store, atomic identity, and the crash seam (P13-A)

The adapter preserves the design-§11 capabilities but corrects the call boundary needed
for invariant 38: `put_schedule(..., expected_revision:)`, `disable_schedule`,
`materialize_due(now:, owner:, lease_for:, limit:, request_template:)`,
`renew_occurrence_lease`, `complete_occurrence(id, execution_id:, status:, evidence:)`,
`list_occurrences(schedule_id:, cursor:, limit:)`. `materialize_due` is the sole public
claim/create/enqueue operation and returns occurrences whose durable requests already
committed. Separate public `claim_due` then `enqueue_occurrence` calls cannot promise one
transaction and are not conforming. The request template is prevalidated, bounded, and
provider-free; its only substitutions are deterministic occurrence identity fields.

**Seam committed (C1/DC-4):** v1 uses ONE SQLite transaction inside `materialize_due`
for claim → create
occurrence → claim its stable request id → enqueue into the request inbox (all tables in
the same SQLite store). Public `CheckpointStore#enqueue_request` owns a transaction and
MUST NOT be called from this transaction. The `tamoz-sqlite` implementation extracts one
private `enqueue_request_in_transaction!(tx, ...)` primitive; the public enqueue method
and the scheduler adapter both delegate to it. `tamoz-scheduler` never reaches into the
adapter; its `ScheduleStore#materialize_due` contract is implemented wholly inside
`tamoz-sqlite`. No nested transaction or two-commit substitute conforms. A crash at any
point leaves old-or-complete-new state; a repeated delivery re-runs the same transaction,
and dedup lives in the shared enqueue primitive: the row key is `(thread_id, namespace, request_id)`,
and a duplicate id is accepted only when input_digest, operation, delivery mode, and
payload digest all match; any byte difference raises `CheckpointConflictError`.

**Load-bearing requirement (C1c):** the enqueued request payload is byte-deterministic
from the occurrence identity + `payload_ref` — no enqueue-time stamp or other
nondeterministic byte inside the payload — so a delivery retry re-materializes an
identical payload and the idempotent join holds. A test asserts payload determinism
across repeated enqueues of the same occurrence.

The scheduler records delivery; the agent records execution; a green enqueue is never
reported as a successful task (no false green — hard zero). Adapters without atomic CAS +
durable occurrence uniqueness do not conform.

Proof: claim-winner test (two processes → one wins the fence, loser sees claimed, one
request row); kill at every statement between claim and enqueue (transaction rolls back
to fully unclaimed, or commits occurrence + request together; no intermediate claim
survives); retry with a higher fence completes exactly once; payload
determinism test; enqueue-conflict test (byte-different duplicate → `CheckpointConflictError`).

## 5. Misfire, overlap, backpressure (P13-B)

Misfire policies (design §6): `skip`, `latest` (default for recurring), `replay` (up to
`misfire_limit`), `fire_once` (default for one-shots). No unbounded catch-up: finite
`misfire_limit`, maximum age, scan batch size; coalescing explicit in history.

Overlap policies (design §7): `forbid` (default), `queue_one`, `allow` (up to
`max_concurrency`). Concurrency enforced from durable occurrence state, never a
process-local mutex; per-thread graph leases remain the final serialization boundary.
Queue depth, global in-flight, tenant concurrency, token/cost, delivery volume all have
budgets; exhaustion delays/skips with a reason, never an unbounded backlog.

Lifecycle operations: pause prevents future claims (does not cancel running); cancel
targets a specific occurrence/execution; delete tombstones the schedule, preserves
definitions/run history, and makes late claims with an old revision fail their fence
check.

Retry separation (design §10): delivery retry (same occurrence/request id) ≠ graph
recovery (resume same accepted execution) ≠ application retry (new reviewed attempt only
when effect safety permits). Scheduler backoff never replays an ambiguous external
effect; recurring schedules never use the next occurrence as a retry of the previous
one. Consecutive scheduler/execution failures open the durable circuit (P12 record,
scheduler scope).

Proof: per-misfire-policy test; per-overlap-policy test; bounded-backlog test; reclaim-
with-higher-fence test; tombstone-delete fence-fail test; three-retries-separation test.

## 6. Time, timezone, DST (P13-D/E)

Storage and comparison use UTC instants. Cron calculation uses its pinned IANA timezone
and records timezone database/version evidence when available. Two DST edge cases are
named tests (C3, design §8 defaults pinned as expected values):

- **Forward gap (nonexistent local time):** skip that civil occurrence and record
  `nonexistent_local_time`; never fire, never substitute an adjacent instant.
- **Backward fold (repeated local time):** fire once at the earlier matching instant by
  default; the explicit `both` option fires two occurrences ONLY when the user accepts
  two (gate asserted).
- **Clock rollback** cannot duplicate an occurrence (identity = nominal UTC instant +
  durable uniqueness).

Gap/fold detection contract on top of fugit: fugit computes instants; the scheduler
detects a forward-gap (a nominal local instant with no UTC mapping) and a backward-fold
(multiple UTC mappings) per its pinned timezone and applies the policy above. Jitter is
deterministic from the occurrence id within the configured window. Tests use an injected
wall/monotonic clock; production waiting uses monotonic duration but recomputes due
state from durable UTC time after wake.

Proof: the two DST named tests + clock-rollback test + deterministic-jitter test +
replay-equivalent histories.

## 7. Authority and unattended execution (P13-C)

A scheduled task is delayed authority, not a future blank cheque (design §9): the record
pins owner/provenance, payload/skill/capability digests, maximum grant + scopes, behavior
version adoption, budgets, approval + escalation destination, delivery + data-retention
policy.

**Enforcement point (C2, invariant 40) — pinned contract:** the intersection is computed
twice: (a) at `claim_due`/enqueue time, the scheduler intersects the stored maximum
grant against current operator policy (P8 profile) and skips/escalates any narrowing or
revocation; (b) at execution time, the agent's existing session-authority binding
(P8 `profile_authority` snapshot, re-validated on resume) re-intersects — an old
schedule cannot retain removed authority. **In-flight semantics:** an occurrence whose
plan is already accepted either completes under the accepted plan (invariant 26 binding)
or is cancelled at the next safe barrier; the plan picks complete-under-accepted-plan
and tests it. This is the invariant-40 conformance test.

Every scheduled task drafts and reviews a plan (invariant 25). A pre-authorized
deterministic review policy may accept only within the stored definition and risk class.
Interactive approval defaults to deny or explicit escalation (no human assumed present).
Missing credentials, unavailable capabilities, or material ambiguity skip/escalate —
never silently substitute defaults.

Self-management: the agent cannot edit its schedule while executing unless the original
grant includes narrow self-management; that grant may pause/delete only the current
schedule; changing payload/cadence/capabilities/approval/delivery is a separately
reviewed update.

Proof: claim-time intersection test (revocation between revisions → job narrowed/
disabled at claim); execution-time re-validation test; in-flight-revocation test
(complete-under-accepted-plan asserted); headless deny/escalate test; narrow
self-management test.

## 8. Product consumer (P13-P)

One safe recurring task ships: a recurring READ-ONLY scorecard summary (rerun
`tamoz-eval scorecard agent-smoke` and deliver the summary through the ordinary delivery
policy). **Pinned surface (C8):** the consumer's grant contains ONLY the scorecard-run
tools (the `tamoz-evals` subprocess invocation), no mutation tools; its risk class is
read-only; its `approval_policy` is deterministic and read-only-only; its
`delivery_policy` is ordinary delivery, never reported as execution success. Its
definition digest binds the payload_ref and the deterministic review policy may accept
only within this stored definition + read-only risk class. This is the proof that a real
recurring task survives kill/crash at every seam and never duplicates a logical turn.

Proof: consumer grant-allowlist test (no mutation tool in the surface); kill-at-seam
proof with zero duplicate logical turns; delivery-vs-execution status separation test.

## 9. Evaluation (P13-E)

The deterministic suite uses a fake clock and a reference model (design §12): crash at
every claim/enqueue/complete seam; 2–50 concurrent owners; duplicate wakeups and
delayed/out-of-order delivery; the two DST edge cases + leap days + timezone changes +
clock rollback/jump + long downtime; every misfire/overlap combination with bounded
backlog; edit/disable/delete races and stale fencing tokens; grant revocation, behavior
changes, unavailable capabilities, headless approval; delivery-retry vs graph-resume vs
unsafe application retry; deterministic jitter and replay-equivalent occurrence
histories.

Behavioral metrics: scheduled task success, unnecessary wakeups, false-green rate,
duplicate logical turns, missed occurrences, approval violations, recovery time, cost,
delivery correctness. Release requires: zero duplicate logical turns, zero authority
widening, zero fabricated approval, a complete durable reason for every due occurrence.

## 10. Migration and compatibility (C4)

New tables use the next checksummed migration after the activation baseline (expected
`MIGRATION_3` after P11's expected `MIGRATION_2`; never hard-code/reuse an occupied
ordinal), with `PRAGMA user_version` bump, `application_id`, and
`tamoz_schema_migrations`: `tamoz_schedules`,
`tamoz_occurrences` (with occurrence-transition history), and the scheduler's portion of
the durable circuit record. Safety argument: existing tables
(`tamoz_threads/namespaces/requests/checkpoints/effects/...`) are untouched; occurrences
reference `tamoz_requests` by request id only; invariant-18 versioned records apply to
the new store. Old databases migrate forward; a pre-P13 database without scheduler
tables loads with scheduler disabled (legacy semantics, never a partial load). Migration
test: fresh + old-database paths both pass `rake ci`.

## 11. Failure model (C5)

| Situation | Type (reuse existing where semantics match) | Behavior |
|---|---|---|
| store CAS conflict | `Tamoz::Core::CheckpointConflictError` family | re-poll the due scan; never crash the poller |
| occurrence fence rejection (stale) | `LeaseLostError` semantics | reclaim with higher fence; if the old revision was tombstoned, the claim fails closed |
| misfire limit reached | typed `MisfireLimitReached` result | record `skipped(reason: limit)`; next future occurrence continues |
| circuit open | `CircuitOpen` (P12 record, scheduler scope) | no new claims; safe observation only; time alone never resets |
| revocation / grant narrowing | typed denial → skip/escalate | never enqueue under stale authority (invariant 40) |
| clock rollback detected | `ClockRollbackError` semantics | no duplicate occurrence possible (identity + uniqueness); recompute from durable UTC |

Adapter-thrown errors map onto these classes; a conforming adapter throwing is a typed
failure, not a poller crash.

## 12. Deferrals (explicit, with entry conditions)

- **Cron kind + IANA/DST (P13-D/E part)** — deferred to a follow-up round, recorded per
  the gauntlet simplification mandate (Round 24). The v1 slice ships the `at` and
  `interval` kinds only: elapsed-time cadence and one-shot nominal instants are pure UTC
  arithmetic, need no `fugit` dependency, and keep invariants 38–40 fully non-vacuous for
  the shipped kinds (identity = nominal UTC instant + durable uniqueness; no civil-time
  surface to be wrong about). The recurring read-only scorecard consumer uses `interval`,
  which proves the card outcome ("one recurring read-only product task materialized into
  the ordinary durable request inbox exactly once per logical occurrence") end to end.
  Entry condition for cron: add `fugit` (verified bundleable offline at Round 24; et-orbi
  and raabro are its only runtime deps) and land the two DST named tests (forward gap →
  `nonexistent_local_time`, backward fold → fire once at the earlier instant by default)
  as the entry evidence, per §6 pinned defaults.
- **Additional schedule kinds** (calendar rules, event streams, watchers,
  natural-language) — entry: `tamoz-stream` exists (P14); they belong there.
- **Distributed worker** — entry: a second scheduler process needs coordination beyond
  the store's lease/fence; the store contract already supports multiple pollers.
- **Scheduled result delivery to external surfaces** — entry: P15-G defines the delivery
  surface; v1 delivers through the ordinary request inbox.

## 13. Stop / redesign criteria

- One logical occurrence can be enqueued twice under any crash/race seam (invariant 38
  duplicate-turn hard zero).
- A stored maximum grant can exceed the creating turn's effective grants, or runtime
  authority can widen while delayed/unattended (invariant 40).
- Any occurrence executes without an accepted plan/review, or a pre-authorized review
  policy accepts outside the stored definition/risk class.
- Civil-time handling produces an implicit host-timezone default, or a DST edge case is
  decided nondeterministically or contrary to the §6 pinned defaults.
- An ambiguous external effect is replayed by scheduler backoff, or a recurring schedule
  uses the next occurrence as retry of the previous one.
- Delivery is ever reported as execution success (false green).

## 14. Definition of done (v1)

- [ ] P13-D values/revisions/contract committed (design §3/§5/§11).
- [ ] P13-A SQLite store with CAS/fence, single-transaction occurrence+request identity,
      dedup via `enqueue_request`, byte-deterministic payload.
- [ ] P13-B misfire/overlap/concurrency/backlog/reclaim/pause/disable/delete/cancel with
      separate delivery/execution statuses.
- [ ] P13-C claim-time + execution-time grant intersection; in-flight semantics pinned;
      headless deny/escalate; narrow self-management.
- [ ] P13-P the recurring read-only scorecard consumer with pinned surface; kill-at-seam
      proof with zero duplicate logical turns.
- [ ] P13-E fake-clock suite green incl. the two DST named tests; release gates: zero
      duplicate logical turns, zero authority widening, zero fabricated approval,
      complete per-occurrence reason.
- [ ] Migration: next monotonic Migrator slot (expected `MIGRATION_3` after P11);
      pre-P13 databases load with scheduler disabled; duplicate ordinals fail the gate.
- [ ] **Mandatory** scorecard case `agent.schedule-...` (handover §7) proving the
      consumer's recurring turn; safety counters stay zero.
- [ ] `rake ci` green under both locales; every scorecard case present at P13 start is
      unchanged; the mandatory schedule case is added; safety counters remain zero.
- [ ] Trackers updated; deferrals + fugit version + circuit-scope resolution recorded.
