# Durable task scheduling

How Tamoz turns time into exactly one logical request without confusing schedule delivery
with successful agent behavior.

## 1. Decision

Scheduling ships as `tamoz-scheduler`, a small runtime gem with one responsibility:
**durably materialize due occurrences into the existing request inbox**.

It does not execute agent logic, approve actions, retry arbitrary effects, deliver results,
or keep correctness in process timers. Once an occurrence is enqueued, the ordinary Tamoz
Agent lifecycle owns plan, review, execution, verification, memory, and recovery.

```text
wall clock → schedule calculator → occurrence ledger → request inbox → Tamoz Agent graph
                    durable claim/CAS                ordinary task lifecycle
```

This boundary makes an external scheduler, embedded poller, CLI invocation, and future
distributed worker interchangeable.

## 2. Package boundary

`tamoz-scheduler` depends on `tamoz-core` contracts and a schedule store. It uses `fugit`
for strict cron calculation and IANA timezone handling; natural-language schedule parsing
is not accepted into the durable record. The gem publishes a versioned structural
ScheduleStore contract; it does not require adapter constants. `tamoz-sqlite` implements
the first schedule and occurrence store in an explicitly required optional module.
`tamoz-evals` loads both and verifies the declared contract-version pair.

The gem owns:

- validated schedule values and next-occurrence calculation;
- due scanning, leases/fences, occurrence identity, and enqueue protocol;
- misfire, overlap, jitter, pause, resume, and revision semantics;
- scheduler telemetry and conformance tests.

Tamoz Agent owns payloads, grants, approval destinations, delivery, and user-facing policy.

## 3. Schedule record

```ruby
Schedule = Data.define(
  :id,
  :revision,
  :owner,
  :enabled,
  :kind,                 # :at, :interval, :cron
  :expression,
  :timezone,             # IANA id; required for cron
  :start_at,
  :end_at,
  :misfire_policy,
  :misfire_limit,
  :overlap_policy,
  :max_concurrency,
  :jitter_window,
  :payload_ref,
  :thread_policy,
  :capability_grant,
  :behavior_version,
  :approval_policy,
  :delivery_policy,
  :budgets,
  :created_by,
  :created_at,
  :definition_digest
)
```

Payload and policy artifacts are immutable and content-addressed. Editing creates a new
schedule revision with compare-and-set; it never mutates a definition already used by an
occurrence. An agent may create only a schedule whose grants are a subset of the creating
turn's effective grants. Any widening requires the normal human policy path.

## 4. Supported schedule kinds

| Kind | Meaning | Required semantics |
|---|---|---|
| `at` | one nominal UTC instant | fires at most one logical occurrence |
| `interval` | fixed duration from an explicit anchor | elapsed-time cadence, not civil time |
| `cron` | civil-time recurrence | strict expression plus required IANA timezone |

Calendar rules, event streams, filesystem watchers, natural-language recurrence, and
arbitrary trigger scripts are not v1 schedule kinds. They belong to `tamoz-stream`; its
event-time and processing-time timers are partition state, not civil occurrences.
High-frequency control timing belongs to independently safe automation. This prevents time
calculation from becoming an unattended code-execution surface.

The stored expression is canonical. The CLI may help a human construct it, but displays the
next five instants, timezone, DST behavior, and day-of-month/day-of-week semantics before
approval. Host-local timezone is never an implicit durable default.

## 5. Occurrence identity and state

The logical occurrence id is derived from:

```text
(schedule_id, schedule_revision, nominal_fire_at_utc)
```

Its `request_id` is a deterministic encoding/digest of that occurrence identity.
Jitter changes `not_before`, never the identity or nominal instant. Manual runs use a
caller-supplied request id and do not consume or move the natural occurrence.

```text
due → claimed → enqueued → running → succeeded
        │          │          ├─ failed
        │          │          ├─ cancelled
        │          │          └─ unknown
        │          └─ enqueue retry with same occurrence/request id
        └─ lease expiry → reclaim with higher fence

due → skipped(reason)
due → coalesced(into occurrence id)
```

Creating the occurrence and claiming its stable request id is atomic. Enqueue is either in
the same adapter transaction as the request inbox or uses an outbox record. A crash at any
seam can repeat delivery, but the request inbox commits one logical turn.

The scheduler records delivery. The agent records execution. A green enqueue is never
reported as a successful task.

## 6. Misfire policy

A misfire is an occurrence whose nominal time passed while no eligible scheduler delivered
it. Every schedule chooses one policy:

- `skip` — record every missed occurrence as skipped and calculate the next future one;
- `latest` — coalesce all missed occurrences into the latest one, recording the covered
  range; default for recurring agent turns;
- `replay` — enqueue missed occurrences oldest-first up to `misfire_limit`;
- `fire_once` — emit one recovery occurrence representing the missed window; default for
  one-shot schedules.

There is no unbounded catch-up. `misfire_limit`, maximum age, and scan batch size are
finite. Coalescing is explicit in history so downstream work can distinguish “09:00 run”
from “recovery covering 09:00–13:00”.

## 7. Overlap and backpressure

Every schedule chooses:

- `forbid` — if an earlier occurrence is non-terminal, record the new one as skipped or
  coalesced according to policy; default;
- `queue_one` — retain one bounded pending occurrence and coalesce later ones into it;
- `allow` — run concurrently up to `max_concurrency`.

Concurrency is enforced from durable occurrence state, not a process-local mutex.
Per-thread graph leases remain the final serialization boundary. Queue depth, global
in-flight schedules, tenant concurrency, token/cost spend, and delivery volume all have
budgets. Exhaustion delays or skips with a reason; it never creates an unbounded backlog.

## 8. Time, timezone, and DST

Storage and comparison use UTC instants. Cron calculation uses its pinned IANA timezone and
records the timezone database/version evidence when available.

Civil time has two hard cases:

- nonexistent local time during a forward DST transition: skip that civil occurrence and
  record `nonexistent_local_time`;
- repeated local time during a backward transition: fire once at the earlier matching
  instant by default, with an explicit `both` option only when the user accepts two
  occurrences.

Clock rollback cannot duplicate an occurrence because identity uses the nominal UTC
instant and durable uniqueness. Clock jumps and long suspension are handled as misfires.
Tests use an injected wall/monotonic clock; production waiting uses monotonic duration but
recomputes due state from durable UTC time after wake.

Jitter is deterministic from the occurrence id within the configured window. It spreads
load without changing replay.

## 9. Authority and unattended execution

A scheduled task is delayed authority, not a future blank cheque. The record pins:

- owner and creation provenance;
- payload/skill/capability digests;
- maximum capability grant and filesystem/network scopes;
- behavior version adoption policy;
- model, token, cost, step, wall-clock, and retry budgets;
- approval and escalation destination;
- result delivery and data-retention policy.

At run time the effective grant is the intersection of the stored maximum and current
operator policy. Policy revocation narrows or disables a job; an old schedule cannot retain
removed authority.

Every scheduled agent task still drafts and reviews a plan. A pre-authorized deterministic
review policy may accept only within the stored definition and risk class. Interactive
approval defaults to deny or explicit escalation because no human is assumed present.
Missing credentials, unavailable capabilities, or material ambiguity skip/escalate rather
than silently substituting defaults.

The agent cannot edit its schedule while executing unless the original grant includes
narrow self-management. That grant may pause or delete only the current schedule; changing
payload, cadence, capabilities, approval, or delivery creates a separately reviewed update.

## 10. Failure, retry, and cancellation

Three retries remain separate:

1. **delivery retry** repeats enqueue with the same occurrence/request id;
2. **graph recovery** resumes the same accepted execution;
3. **application retry** is a new reviewed attempt only when effect safety permits.

Scheduler backoff never replays an ambiguous external effect. Recurring schedules do not
use the next natural occurrence as a retry of the previous one.

Pause prevents future claims but does not imply cancellation of a running occurrence.
Cancel targets a specific occurrence/execution and follows graph/effect cancellation
semantics. Delete tombstones the schedule; it preserves definitions and run history for
audit and makes late claims with an old revision fail their fence check.

Consecutive scheduler or execution failures can open a durable circuit. The circuit records
scope, reason, threshold evidence, next probe time, and who may reset it.

## 11. Storage contract

The adapter provides:

```ruby
put_schedule(schedule, expected_revision:)
disable_schedule(id, expected_revision:, reason:)
claim_due(now:, owner:, lease_for:, limit:)
renew_occurrence_lease(id, fence:, lease_for:)
enqueue_occurrence(id, fence:, request:)
complete_occurrence(id, execution_id:, status:, evidence:)
list_occurrences(schedule_id:, cursor:, limit:)
```

`claim_due` must atomically create or claim occurrences and advance calculation state under
a fence. Multiple scheduler processes may poll the same store; uniqueness plus fencing
ensures one logical occurrence. Adapters without atomic compare-and-set and durable
occurrence uniqueness do not conform.

## 12. Evaluation and release gates

The deterministic suite uses a fake clock and reference model over:

- crash at every claim/enqueue/complete seam;
- two to fifty concurrent scheduler owners;
- duplicate wakeups and delayed/out-of-order delivery;
- DST gaps/folds, leap days, timezone changes, clock rollback/jump, and long downtime;
- every misfire/overlap combination with bounded backlog;
- edit/disable/delete races and stale fencing tokens;
- grant revocation, behavior changes, unavailable capabilities, and headless approval;
- delivery retry versus graph resume versus unsafe application retry;
- deterministic jitter and replay-equivalent occurrence histories.

Behavioral suites measure scheduled task success, unnecessary wakeups, false-green rate,
duplicate logical turns, missed occurrences, approval violations, recovery time, cost, and
delivery correctness. Release requires zero duplicate logical turns, zero authority
widening, zero fabricated approval, and a complete reason for every due occurrence.
