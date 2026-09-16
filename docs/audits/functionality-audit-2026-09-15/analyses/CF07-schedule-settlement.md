# CF07 — schedule admission, occurrence leases, and worker execution — IMPROVE

## Row, boundary, and method

- **Row:** CF07 — schedule admission, occurrence leases, and worker execution.
- **Queue:** cross-gem flow inventory in `COVERAGE.md`.
- **Code baseline:** branch `audit-15-09`, commit `582ae55` (2026-09-15).
- **Analyst:** coordinator direct source review after the cross-flow scanner and
  the schedule challenge. No subagent was used for this continuation.
- **Scope:** CLI schedule lifecycle, value validation, SQLite materialization,
  occurrence acknowledgement/completion, worker settlement, and projections.
- **Method:** end-to-end source trace, prior challenge re-read, focused tests;
  no implementation and no production/test/configuration edits.

## Source map and ownership

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb` | 15-29, 32-105, 153-240 | operator schedule add/list/show/pause/resume/remove/run-now commands |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb` | 5-75 | versioned structural store contract |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb` | 7-19, 42-70, 130-143 | schedule kinds, identity, misfire and policy values |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/occurrence.rb` | 7-19, 27-29, 82-101, 137-144 | occurrence identity and state transitions |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | 168-199, 216-254, 279-287, 355-371, 411-451, 487-559 | atomic materialization, history, enqueue, acknowledge, complete, lookup |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` | 408-431 | durable occurrence schema and indexes |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | 147-180, 571-605 | due polling, schedule settlement, terminal status projection |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` | 491-497, 935-1002 | occurrence lookup extension and scheduled-work projection |
| `test/scheduler_contract_test.rb` | 5-10, 14-58 | contract fake and declared keyword parity |
| `test/scheduler_values_test.rb`, `test/scheduler_due_occurrences_test.rb` | current files | value, civil-time, and due-window behavior |
| `test/sqlite_schedule_store_test.rb`, `test/sqlite_schedule_determinism_test.rb` | current files | SQLite lifecycle, idempotence, and deterministic identity |
| `test/agent_schedule_test.rb`, `test/scheduler_consumer_test.rb` | current files | CLI/worker schedule integration and consumer behavior |

The ownership boundary is clear in the normal path. The CLI validates an
operator command and writes a versioned `Schedule`; `tamoz-scheduler` computes
due values and defines storage vocabulary; SQLite atomically materializes an
occurrence and the ordinary request-inbox row; the worker joins the request to
the occurrence, acknowledges execution, runs the graph through its existing
durable path, and completes the occurrence. The scheduler never executes work.

## End-to-end behavior path

1. `cmd_schedule` dispatches lifecycle verbs. `schedule_add` accepts only an
   interval or one UTC instant, stores the task payload separately, binds the
   selected thread profile, and writes the schedule through
   `put_schedule` with an expected revision (`cli_schedule_commands.rb:15-105`).
   Pause/resume are revision-checked enable flips (`:153-180`); remove disables
   and tombstones while retaining occurrence history (`:182-205`). `run-now`
   deliberately submits an ordinary queued `:turn` with a random request id;
   it does not fabricate a nominal occurrence (`:208-240`).
2. The versioned `ScheduleStore` contract declares schedule lifecycle,
   `materialize_due`, `complete_occurrence`, and listing (`schedule_store.rb:5-75`).
   It does not declare `acknowledge_occurrence` or `occurrence_for_request`,
   although the worker uses both through the concrete runtime path.
3. `Worker#materialize_due_schedules` passes the current time, worker grant,
   task resolver, batch, and `lease_for: 60` into SQLite (`worker.rb:147-180`).
   `SQLite::ScheduleStore#materialize_due` scans enabled latest revisions in a
   transaction (`sqlite/schedule_store.rb:168-199`). Grant intersection,
   due-window selection, overlap, misfire, and conflict recording happen before
   `enqueue_occurrence` writes the request and the `enqueued` occurrence in the
   same transaction (`:216-254,279-287,411-451`). The deterministic occurrence
   request id and unique request row make a retry idempotent.
4. The worker later finds the request in its normal work list. It asks the
   runtime for the schedule occurrence. The SQLite runtime extension looks up
   the durable row by request id (`worker_runtime.rb:491-497`; SQLite store
   `:541-559`). If the row is `enqueued`, settlement acknowledges it under the
   occurrence fence and records the execution id (`worker.rb:571-586`; SQLite
   `:487-506`).
5. After the graph produces a terminal view, the worker derives the scheduled
   status from the view's terminal satisfaction and calls `complete_occurrence`
   with evidence (`worker.rb:587-602`). SQLite accepts `succeeded`, `failed`,
   `cancelled`, or `unknown`, but its update predicate binds only occurrence id
   and `state = 'running'` (`sqlite/schedule_store.rb:509-535`). The immutable
   value transition has the same missing execution-id equality check
   (`occurrence.rb:82-101,137-144`).
6. The runtime projection exposes execution, delivery, effect, authority, and
   next-action state (`worker_runtime.rb:935-1002`). An `enqueued` row is shown
   as ordinary queued work and remains non-terminal in the overlap census
   (`:355-371`), so a missing settlement path can block later `forbid` work.

## Correctness

Reviewed. The current SQLite path has useful hard properties: schedule revisions
are compared at lifecycle writes; due materialization and request insertion are
atomic; occurrence and request identity are deterministic; duplicate materialize
attempts do not create a second logical occurrence; and terminal status values
are closed. The seven schedule suites below passed with 71 runs and 336
assertions.

Two existing correctness/ownership defects remain open. `CF07-ARCH-01` is the
contract gap: a conforming adapter that implements only the declared methods
can materialize an occurrence but cannot be joined or acknowledged by the
worker, and the worker's `respond_to?` path returns silently. `CF07-REL-02` is
the execution identity gap: a running row acknowledged for one execution can
be completed by another id because the SQL and value transition do not compare
the acknowledged identity. The full five-whys chains, temporary probes, and
recommendations are recorded in `analyses/occurrence-contract-and-fencing.md`;
the independent challenge in `analyses/challenge-queue-comms-schedule.md`
upholds both findings. They are carried here without a second count.

The adjacent F05 value finding `F05-COR-01` also remains open: an `allow`
schedule with `max_concurrency: 0` is accepted by the value layer but can never
materialize. It is owned by the schedule policy validator and is not a new CF07
finding.

## Security and authority

Reviewed. Schedule ids are constrained by the CLI; schedule writes use expected
revisions; a missing worker grant fails closed at materialization; and the
effective grant is intersected before an occurrence is enqueued. The scheduled
task comes from the operator-owned payload reference rather than a request's
arbitrary payload (`worker.rb:156-160,182-191`). `run-now` still enters the
ordinary session/request path, so no second execution authority is introduced.

The durable schedule authority is delayed: a stored schedule can be admitted
under one grant and later evaluated under the current worker grant. That
narrowing behavior is intentional and is recorded in the occurrence report.
The carried profile, session, sidecar, MCP, and egress findings remain owners of
the broader authority contract (`F25-SEC-01`, `F22-SEC-01`, `F18-SEC-01`, and
the F09/F10 security findings); CF07 adds no bypass evidence. The execution-id
completion gap is also an authority boundary because a caller with a stale or
incorrect id can assert terminal evidence, but its owner remains
`tamoz-sqlite`/`tamoz-scheduler` under CF07-REL-02.

## Reliability and durability

Reviewed. SQLite keeps schedule selection, request insertion, and occurrence
insertion in one transaction. Acknowledgement is fenced by the stored fence and
state, and terminal completion refuses a non-running row. The worker emits a
typed schedule error when those transitions raise.

The durability gap is the missing long-lived lease state. `materialize_due`
accepts `lease_for:` but never reads it (`sqlite/schedule_store.rb:168-199`),
the occurrence schema has no expiry or reclaim column (`migrator.rb:408-426`),
and the current path inserts directly as `enqueued`. The design document still
describes lease expiry/reclaim and renewal (`docs/design-v0.1/SCHEDULER_DESIGN.md:95-124,225-258`).
The prior challenge correctly defers this as a contract/design decision because
there is no persisted long-lived claim to renew in the shipped transaction.
`F05-REL-05` remains the owning major for a lost consumer leaving an enqueued
row and the resulting schedule wedge; `F05-REL-04` owns the unbounded misfire
history. Both remain open and are carried without double-counting.

## Observability and evidence

Reviewed. Schedule materialization and errors have closed catalog events, and
occurrence rows retain schedule, request, fence, owner, state, reason, payload
digest, and timestamps. The scheduled-work projection distinguishes `enqueued`,
`running`, and terminal states, and CLI history can list bounded pages.

There are two evidence weaknesses. First, a contract-only adapter can fail to
settle silently because missing occurrence methods return before an error event;
the operator sees a normal queued projection. Second, completion serializes the
supplied execution id as reason and can overwrite the acknowledged identity.
The first is `CF07-ARCH-01`, the second `CF07-REL-02`. `F05-OBS-06` separately
records that schedule events have no correlation list tying schedule, occurrence,
request, and execution into one trace. No real provider, worker sink, or external
transport was used, so this is durable plumbing evidence only.

## Scalability and resource bounds

Reviewed. Worker schedule scans use the configured batch; SQLite limits schedules
per materialization and due instants per schedule; occurrence listing clamps a
read to 100; and grant intersection operates on the bounded policy arrays.
These bounds keep one scan finite.

The bounded scan does not bound durable history. `record_misfire_skips` writes one
row for every skipped instant and has no age/count retirement, while a permanently
stuck enqueued occurrence causes later cadence instants to accumulate skipped
rows. `F05-REL-04` (minor after coordinator challenge) and `F05-REL-05` (major)
own those open reliability/resource findings. No sustained load, multi-process worker race, long outage, or large
schedule catalog run was performed; the absence is an evidence limitation.

## Maintenance and architecture

Reviewed. The intended seams are small and understandable: CLI command parsing,
pure scheduler values, SQLite transaction ownership, and worker execution. The
normal path reuses the ordinary request inbox rather than creating a scheduler
execution loop. The contract is versioned and a fake checks declared keyword
parity (`test/scheduler_contract_test.rb:14-58`).

The maintenance defect is that the versioned contract is not the single source
of truth for its only consumer. SQLite's `acknowledge_occurrence` and
`occurrence_for_request` are concrete extensions, while the worker assumes them
when settlement is needed. The design document also names the old `claim_due`
and `renew_occurrence_lease` vocabulary while the implementation exposes
`materialize_due`. `CF07-ARCH-01` and the existing F05 documentation lead cover
these mismatches. The smallest action is to choose one explicit contract surface
and align the worker, adapter, fake, and design text at that seam; no new
execution abstraction is justified by this audit.

## Focused tests and contracts

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/scheduler_values_test.rb` | 17 | 112 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_contract_test.rb` | 3 | 21 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_due_occurrences_test.rb` | 9 | 24 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_consumer_test.rb` | 8 | 26 | 0 | 0 | 0 |
| `ruby -Itest test/sqlite_schedule_determinism_test.rb` | 4 | 15 | 0 | 0 | 0 |
| `ruby -Itest test/sqlite_schedule_store_test.rb` | 21 | 73 | 0 | 0 | 0 |
| `ruby -Itest test/agent_schedule_test.rb` | 9 | 65 | 0 | 0 | 0 |

The suites cover current value validation, deterministic identity, atomic
materialization, revision conflicts, pause/resume/remove, and ordinary worker
completion. They do not cover an alternate adapter through worker settlement,
wrong execution id while the row is still running, lost consumer recovery,
lease expiry/reclaim, long-outage history bounds, or the `max_concurrency: 0`
case. Those are existing finding or evidence gaps, not passing assumptions.

## Findings and coordinator disposition

No new machine-counted CF07 finding is added. Existing findings are carried with
their original owner, challenge, and five-whys record:

| Finding | CF07 disposition | Owning seam / evidence |
|---|---|---|
| CF07-ARCH-01 | **Open major, upheld.** The worker requires two lifecycle methods omitted from the versioned contract; a conforming alternate adapter can remain enqueued without an error. | `ScheduleStore`, `WorkerRuntime#schedule_occurrence`; `occurrence-contract-and-fencing.md`, `challenge-queue-comms-schedule.md` |
| CF07-REL-02 | **Open major, upheld.** Completion does not compare the supplied execution id with the acknowledged identity. | SQLite/value occurrence completion; same report and challenge |
| F05-REL-04 | **Open minor, carried.** Misfire skip history has no age/count retirement; the coordinator challenge bounded its impact to per-scan/history debt. | F05 scheduler report |
| F05-REL-05 | **Open major, carried.** A lost consumer can leave an enqueued occurrence and wedge later work; no expiry/reclaim exists. | F05 scheduler report and schedule challenge |
| F05-REL-01 | **Open minor, carried.** Schedule digest integrity is not recomputed at the relevant store boundary. | `schedule-digest-integrity.md` |
| F05-COR-01 | **Open minor, carried.** `max_concurrency: 0` is accepted but undeliverable under `allow`. | F05 scheduler report |
| F05-OBS-06 | **Open minor, carried.** Schedule events lack a correlation list across schedule/occurrence/request/execution. | F05 scheduler report |
| F05-REL-02 | **Duplicate of CF07-REL-02 for this flow; no new count.** The value-level execution identity omission is the same boundary. | F05 scheduler report and occurrence report |
| F07-REL-01 | **Adjacent queue finding; no CF07 duplicate.** Request-claim starvation can delay a scheduled request after materialization. | `challenge-queue-comms-schedule.md` |

The challenge record explicitly upholds the two CF07 majors and defers only the
lease/reclaim design choice. The rollup therefore keeps CF07 counts at zero and
does not inflate the repository-wide finding totals.

## Blind spots and verdict

- No alternate non-SQLite adapter was driven through the worker's settlement
  method; the fake contract proves the omission and the temporary probe proves
  the silent enqueued state.
- No in-tree caller supplying a mismatched completion execution id was found;
  the SQLite behavior was reproduced directly while the row was running.
- No lost-consumer, lease-expiry, reclaim, long-outage, multi-process race, or
  sustained schedule-load run was performed.
- No real model, provider, MCP service, sink, network endpoint, or external
  authorization layer was used.
- No production code, tests, configuration, or generated artifact was changed.

**IMPROVE** under `BAR.md`: all six lenses and the CLI → scheduler → SQLite →
worker → graph boundary are reviewed, but two open major CF07 findings and the
carried F05 schedule history/lease findings cross the closure threshold. CF07
adds no duplicate machine-counted record.
