# Durable task scheduling (`tamoz-scheduler`)

`tamoz-scheduler` turns time into exactly one logical request — durably materializing due occurrences into the existing request inbox — without confusing schedule delivery with successful agent behavior.

Source: [`docs/design-v0.1/SCHEDULER_DESIGN.md`](../../docs/design-v0.1/SCHEDULER_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## The boundary

```text
wall clock → schedule calculator → occurrence ledger → request inbox → Tamoz Agent graph
                    durable claim/CAS                ordinary task lifecycle
```

The scheduler does **not** execute agent logic, approve actions, retry arbitrary effects, deliver results, or keep correctness in process timers. Once an occurrence is enqueued, the ordinary agent lifecycle owns plan, review, execution, verification, memory, and recovery. This makes an external scheduler, an embedded poller, a CLI invocation, and a future distributed worker interchangeable.

## Schedule and occurrence values

A `Schedule` is a validated value: id and revision, owner, enabled flag, kind (`:at` | `:interval` | `:cron`), expression, required IANA timezone (for cron), start/end, misfire and overlap policies, jitter window, payload reference, thread policy, capability grant, behavior version, approval and delivery policy, **budgets**, provenance, and a definition digest.

- Payload and policy artifacts are immutable and content-addressed. Editing creates a new schedule revision with compare-and-set; it never mutates a definition already used by an occurrence.
- The **logical occurrence id** is derived from `(schedule_id, schedule_revision, nominal_fire_at_utc)`, and its request id is a deterministic encoding of that identity. Jitter changes `not_before`, never the identity or nominal instant.
- Creating the occurrence and claiming its stable request id is atomic; enqueue shares the adapter transaction with the request inbox (or uses an outbox record). A crash at any seam can repeat delivery, but the inbox commits one logical turn.
- The scheduler records delivery; the agent records execution. A green enqueue is never reported as a successful task.

Schedule kinds: `at` fires at most one logical occurrence; `interval` is elapsed-time cadence from an explicit anchor; `cron` is civil-time recurrence with a strict expression and pinned IANA timezone. In the current release `cron` is a recorded deferral — the shipped kinds are `at` and `interval` (see [limitations.md](../limitations.md), invariant 39, for implementation status). Calendar rules, event streams, filesystem watchers, natural language, and arbitrary trigger scripts are not schedule kinds — they belong to the stream runtime, and high-frequency control timing belongs to independently safe automation.

## The ScheduleStore contract

`tamoz-scheduler` publishes a versioned structural contract implemented by `tamoz-sqlite` (and verified by `tamoz-evals`):

```ruby
put_schedule(schedule, expected_revision:)
disable_schedule(id, expected_revision:, reason:)
claim_due(now:, owner:, lease_for:, limit:)
renew_occurrence_lease(id, fence:, lease_for:)
enqueue_occurrence(id, fence:, request:)
complete_occurrence(id, execution_id:, status:, evidence:)
list_occurrences(schedule_id:, cursor:, limit:)
```

`claim_due` must atomically create or claim occurrences and advance calculation state under a fence. Multiple scheduler processes may poll the same store; uniqueness plus fencing ensures one logical occurrence. Adapters without atomic compare-and-set and durable occurrence uniqueness do not conform.

## Due occurrences and the request inbox

A due occurrence is atomically claimed and delivered to the existing request inbox with a stable request id; the ordinary agent graph then plans, reviews, executes, and verifies it. Delivery success and task success remain separate.

## Budgets

Every schedule pins budgets: `max_steps`, `max_wall_seconds`, and `max_cost_tokens` (validated as positive integers within a bounded magnitude), plus model/token/cost and retry budgets where the agent layer applies them. Queue depth, global in-flight schedules, tenant concurrency, token/cost spend, and delivery volume all have budgets; exhaustion delays or skips with a reason and never creates an unbounded backlog.

## Misfire, overlap, and DST semantics

A misfire is an occurrence whose nominal time passed while no eligible scheduler delivered it. Every schedule picks one policy: `skip` (record each missed occurrence, calculate the next future one), `latest` (coalesce all missed occurrences into the latest, recording the covered range — default for recurring turns), `replay` (enqueue missed occurrences oldest-first up to `misfire_limit`), or `fire_once` (one recovery occurrence for the missed window — default for one-shot schedules). There is no unbounded catch-up; `misfire_limit`, maximum age, and scan batch size are finite.

Overlap policies: `forbid` (if an earlier occurrence is non-terminal, record the new one as skipped or coalesced — default), `queue_one` (retain one bounded pending occurrence and coalesce later ones into it), or `allow` (run concurrently up to `max_concurrency`). Concurrency is enforced from durable occurrence state, not a process-local mutex; per-thread graph leases remain the final serialization boundary.

Storage and comparison use UTC instants; cron calculation uses its pinned IANA timezone. Civil time has two hard cases: nonexistent local time during a forward DST transition is skipped and recorded as `nonexistent_local_time`; a repeated local time during a backward transition fires once at the earlier matching instant by default, with an explicit `both` option only when the user accepts two occurrences. Clock rollback cannot duplicate an occurrence because identity uses the nominal UTC instant; clock jumps and long suspension are handled as misfires. Jitter is deterministic from the occurrence id.

## Delayed authority

A scheduled task is delayed authority, not a future blank cheque. The record pins owner, payload/skill/capability digests, maximum capability grant and filesystem/network scopes, behavior-version adoption, budgets, approval/escalation destination, and delivery/retention policy. At run time the effective grant is the intersection of the stored maximum and current operator policy — revocation always wins. Every scheduled task still drafts and reviews a plan; interactive approval defaults to deny or explicit escalation because no human is assumed present. An agent may create only a schedule whose grants are a subset of the creating turn's effective grants, and may self-manage only within an explicitly granted narrow self-management scope.

## Failure, retry, and cancellation

Three retries stay separate: delivery retry repeats enqueue with the same occurrence/request id; graph recovery resumes the same accepted execution; application retry is a new reviewed attempt only when effect safety permits. Scheduler backoff never replays an ambiguous external effect. Consecutive scheduler or execution failures can open a durable circuit recording scope, reason, threshold evidence, next probe time, and who may reset it.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../operations/operations.md`](../operations/operations.md) — operating schedules
- [`../reference/config.md`](../reference/config.md) — schedule configuration surface
- [`../reference/cli.md`](../reference/cli.md) — the `tamoz schedule` command surface
- [`../../docs/design-v0.1/SCHEDULER_DESIGN.md`](../../docs/design-v0.1/SCHEDULER_DESIGN.md) — the authoritative design record
