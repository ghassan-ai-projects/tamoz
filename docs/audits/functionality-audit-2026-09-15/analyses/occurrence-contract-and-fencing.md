# CF07 — occurrence contract and execution fencing

| Finding | Scope | Severity | Confidence | Status |
|---|---|---|---|---|
| CF07-ARCH-01 | Worker settlement requires two SQLite-only occurrence methods absent from the versioned store contract | **Major** | **High** | **Open, confirmed** |
| CF07-REL-02 | Completion accepts an execution id different from the one acknowledged for the running occurrence | **Major** | **High** for the store behavior; medium for an in-tree mismatched caller | **Open, confirmed** |

## CF07-ARCH-01 — a conforming store can never settle an occurrence

The scheduler says `ScheduleStore` is a versioned structural contract and that
conforming adapters are interchangeable (`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:5-8`).
Its v2 surface declares `put_schedule`, lifecycle methods, `materialize_due`,
`complete_occurrence`, and `list_occurrences` only (`:17-75`). It does not declare
`acknowledge_occurrence` or `occurrence_for_request`.

The worker settlement path requires both methods. `WorkerRuntime#schedule_occurrence`
returns immediately when the store lacks `occurrence_for_request`
(`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:491-497`), and
`Worker#settle_schedule_occurrence` then returns on the resulting `nil`, before
acknowledgement or completion (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:571-587`).
The concrete SQLite adapter supplies both extensions (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:487-559`),
so the normal path hides the boundary defect. The contract fake deliberately
implements exactly the declared methods (`test/scheduler_contract_test.rb:14-29`),
but the parity test checks only those declared methods (`:49-58`).

The temporary fake probe materialized an `enqueued` occurrence, ran the worker's
settlement method, and reported:

```text
fake_store_responds_to_ack=false lookup=false
post_settlement_state=:enqueued
```

This is silent. No `schedule.error` is emitted. An enqueued row remains
non-terminal and pending in SQLite's overlap census (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:355-370`),
so a default `forbid` schedule can skip later due occurrences indefinitely. The
projection presents this as ordinary `queued`/`enqueued` work rather than a
contract failure (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:975-993`).

Five whys: settlement needs lookup and acknowledgement because the worker must
join the request to its occurrence; those methods were added as concrete
extensions; the versioned interface was not updated; `respond_to?` was used to
preserve a nil-safe path; the root cause is a public interchangeability contract
that is not the single source of truth for its clients.

Recommendation: promote the two lifecycle methods into the versioned contract
with a deliberate contract revision, or explicitly define a separate required
worker extension and fail fast before materialization. Extend the fake and add a
worker-level alternate-adapter test that asserts enqueue → running → terminal
and a second interval remains eligible.

## CF07-REL-02 — completion is not bound to the acknowledged execution

`acknowledge_occurrence` transitions `enqueued` to `running` only under the
occurrence fence, while recording the supplied execution id in `reason`
(`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:487-505`).
`complete_occurrence` validates only the terminal status and updates any row
matching `occurrence_id AND state = 'running'`; its SQL never compares the
supplied execution id with the recorded one (`:511-535`). The immutable value
state machine has the same omission: `running` stores one id and terminal
transitions accept another (`gems/tamoz-scheduler/lib/tamoz/scheduler/occurrence.rb:82-101,137-144`).

A real SQLite temporary-database probe acknowledged `exec-good`, then completed
the still-running occurrence with `exec-wrong`:

```text
wrong_execution_completion=:accepted
stored_state=:failed reason={"execution_id"=>"exec-wrong", ...}
```

The in-tree worker normally carries one id from the durable view/request into
both calls (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:577-601`), so no current
CLI path was shown to supply a mismatch. The store boundary nevertheless permits
a stale, buggy, or unauthorized caller to mark a live occurrence succeeded or
failed under a different execution, producing false execution evidence and
breaking the identity needed for recovery/fencing.

Five whys: the wrong completion succeeds because the SQL predicate binds only
row id and state; the execution id is serialized as evidence rather than a CAS
condition; acknowledgement and completion were implemented as separate writes;
the contract exposes execution identity but no required equality rule; tests
only try a second completion after the row is already terminal
(`test/sqlite_schedule_store_test.rb:533-565`). The root cause is missing
execution-identity enforcement at the existing completion seam.

Recommendation: in the completion transaction, read/compare the execution id
recorded by acknowledgement and refuse a mismatch with the existing typed
lease/scheduler error. Add a mismatch-while-running regression and assert that
the state and evidence remain unchanged.

## Lease/reclaim challenge and six-lens assessment

The scanner's additional lease lead is a qualified contract gap, not a separate
current major finding. `materialize_due` accepts `lease_for:` but never reads it
or passes it below the transaction (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:168-199`);
the occurrence table has no expiry column (`gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:408-426`),
and the current implementation inserts directly as `enqueued` (`:413-450`).
The design still describes `claimed → ... → lease expiry → reclaim` and a
`renew_occurrence_lease` API (`docs/design-v0.1/SCHEDULER_DESIGN.md:107-124,222-239`),
while the implementation removed the dead renew method. Because the shipped
materialization is one atomic transaction, there is no persisted long-lived
claim in this path to renew or reclaim. Either revise the design/contract to
make that simplification explicit, or implement the full lease state; do not
claim reclaim proof until one is chosen. The same no-op was explicitly deferred
in the prior audit (`docs/audits/top100-audit-2026-09-11/026-schedule_store.md:34-38`).

| Lens | Current evidence |
|---|---|
| Correctness | A contract-only adapter leaves delivery forever enqueued; completion can record the wrong execution. |
| Security/authority | No direct CLI authority bypass was found; a store caller can nevertheless assert terminal execution without identity proof. |
| Reliability/durability | A stuck enqueued row blocks default overlap progression; current atomic materialization limits the lease gap to a design mismatch. |
| Observability/evidence | Missing methods fail silently; wrong completion overwrites the only execution evidence. |
| Scalability/resource bounds | Permanent enqueued rows count as in-flight and can turn recurring work into skipped history; no new memory bound was found. |
| Maintenance/architecture | The worker, SQLite adapter, structural contract, and scheduler design disagree on the lifecycle surface. |

Focused runs passed: `test/scheduler_contract_test.rb` (3 runs, 21 assertions),
`test/sqlite_schedule_store_test.rb` (21/73), `test/agent_schedule_test.rb`
(9/65), and the scorecard baseline including the schedule case (1/149).
None tests an alternate adapter through worker settlement, wrong execution id
while running, or a lease expiry/reclaim scenario. No multi-process stale caller,
external authorization layer, or real provider execution was exercised.

**Disposition:** accept CF07-ARCH-01 and CF07-REL-02 as open major findings;
carry the lease/reclaim item as a deferred contract decision, with no severity
promotion absent a defined long-lived claim requirement.
