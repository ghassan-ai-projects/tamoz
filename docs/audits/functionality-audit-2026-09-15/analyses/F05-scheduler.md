# F05 `tamoz-scheduler` — IMPROVE: a non-executing, honestly-typed value gem whose store contract omits the operations settlement and clock safety actually need

Row / queue / baseline:
- Row: **F05** — `tamoz-scheduler`, queue **W2B** (cancellation / concurrency / scheduler)
- Baseline: branch `audit-15-09`, HEAD `582ae55`, 2026-09-15
- Analyst: independent read-only functionality auditor, row F05
- Budget: ~40 minutes target / 60 minutes cap

---

## Scope and source map

Read end to end, every line, in this order.

| Surface | Lines | Role |
|---|---:|---|
| `gems/tamoz-scheduler/lib/tamoz/scheduler.rb` | 9 | entry point; requires `tamoz/core` + 6 relative files |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb` | 425 | `Schedule` value: validation, digest, fire calculus, misfire/overlap/jitter |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/occurrence.rb` | 177 | `Occurrence` value: identity, request id, closed state machine |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb` | 79 | the **contract** (this is the row's contract) |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/grant_intersector.rb` | 129 | pure grant intersection (invariant 40) |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/errors.rb` | 43 | 5 typed errors |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-scheduler/tamoz-scheduler.gemspec` | 14 | one dependency: `tamoz-core` |
| `gems/tamoz-scheduler/README.md` | 34 | documented v1 scope |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | 737 | **the one real implementer** (row F07 owns it; read here as this row's implementation) |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:405-435` | 31 | `tamoz_occurrences` schema |
| `documentation/design/scheduling.md` | 75 | design claim surface |
| `documentation/architecture/invariants.md:41-43` | 3 | scheduling clause summary (38–40) |
| `docs/design-v0.1/INVARIANTS.md:94-96,167-169` | 6 | authoritative clause text + conformance shapes |
| `documentation/limitations.md:77-86` | 10 | the "Cron and civil-time scheduling" claim |
| `docs/design-v0.1/SCHEDULER_DESIGN.md:100-124,229-239,241-262` | — | design state machine, lease/reclaim, release gates |

Callers read (the gem has no callers inside itself; the behavior path leaves it):

- `gems/tamoz-agent/lib/tamoz/agent/worker.rb:147-185` (`materialize_due_schedules`), `:571-608` (`settle_schedule_occurrence`)
- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:483-497,930-993` (projection + occurrence lookup)
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb:33-110,140-260`
- `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:104-113`

**Entry seam.** `Tamoz::Scheduler` is loaded by `require "tamoz/scheduler"` (`scheduler.rb:1-9`). The value entry is `Schedule.new` (`schedule.rb:49-71`); the contract entry is `ScheduleStore#materialize_due` (`schedule_store.rb:61-64`), which the worker calls through `runtime.schedule_store` (`worker.rb:151`).

---

## Behavior path

Step by step, with `file:line`, for one recurring occurrence:

1. **Operator creates a schedule.** CLI builds a `Schedule` and CAS-writes it: `cli_schedule_commands.rb:83-102`. The store serializes `schedule.to_h` to JCS and inserts a new revision row (`sqlite/schedule_store.rb:54-90`).
2. **Poller materializes.** `worker.rb:147-165` calls `store.materialize_due(now: Time.now.to_i, owner:, lease_for: 60, limit: @batch, request_template: ->(schedule){...}, include_provenance: false, current_grant: @runtime.worker_grant)`.
3. **Grant gate.** `enforce_claim_grant` intersects the stored maximum against current policy; `nil` current policy fails closed and every due instant is recorded `skipped / grant_revoked` (`sqlite/schedule_store.rb:222-223,259-265,386-393`).
4. **Due window.** `schedule.due_occurrences(now:, limit:)` (`schedule.rb:106-115`) → `due_interval_occurrences` (`:258-265`) enumerates `anchor + ordinal*duration` oldest-first, truncated to `limit`.
5. **Misfire selection.** `misfire_selection(due)` (`schedule.rb:130-144`) splits the window into `materialize` vs `skipped`; the skipped half gets durable terminal rows first (`sqlite/schedule_store.rb:245-248,281-288`).
6. **Overlap gate.** `occurrence_state` counts durable `claimed|enqueued|running` and `enqueued` rows (`sqlite/schedule_store.rb:358-371`); `overlap_decision` decides per instant (`:294-351`).
7. **Enqueue + occurrence insert, one transaction.** `enqueue_occurrence` (`sqlite/schedule_store.rb:413-451`) derives `request_id = Occurrence.request_id(identity)`, writes the request through the shared inbox primitive, and inserts the occurrence row as `enqueued` with `fence = now_ms`.
8. **Fenced acknowledgement.** Worker joins the occurrence by `request_id` (`worker_runtime.rb:491-497` → `sqlite/schedule_store.rb:541-559`), then `acknowledge_occurrence(id, execution_id:, fence:)` transitions `enqueued → running` **only** under `state='enqueued' AND fence=?` (`sqlite/schedule_store.rb:487-507`).
9. **Completion.** `complete_occurrence(id, execution_id:, status:, evidence:)` (`sqlite/schedule_store.rb:511-536`) writes a terminal status from `running`.
10. **Projection.** `scheduled_work_document` renders state, effective grant and `definition_digest` for the operator (`worker_runtime.rb:936-963`).

**Where execution happens:** nowhere in this gem. Step 8/9 are the *agent's* graph and worker, in `tamoz-agent`. See the proof below.

---

## Lens: correctness

Reviewed. Evidence:

- **Occurrence identity is deterministic and jitter-independent.** `Occurrence.identity(schedule_id, schedule_revision, nominal_fire_at_utc)` (`occurrence.rb:33-38`) and `request_id` as a digest of that identity (`:42-44`). Probe: two occurrences with different `not_before` produce the **same** `occurrence_id` and `request_id`. Confirmed: jitter cannot split or duplicate identity.
- **`definition_digest` does not feed identity.** `identity` uses only id/revision/instant (`occurrence.rb:34-37`); `compute_digest` deliberately excludes `definition_digest` (`schedule.rb:79-84`). So the digest defect (prior F05-REL-01, carried below) cannot create or destroy an occurrence.
- **`at` values are validated as real instants, not shapes.** `validate_expression!` regex-checks then calls `at_instant` (`schedule.rb:352-363`), which round-trips the calendar and raises `Tamoz::ConfigurationError` for a rolled-over date (`:191-203`). Probe: `"2026-8-3T1:2:3Z"`, `"2026-13-01T00:00:00Z"` and `"9999-99-99T99:99:99Z"` all raise `Tamoz::ConfigurationError`, never a raw `ArgumentError`. This is a real, verified fix of the class of defect the file's own comment describes (`:178-190`).
- **The interval calculus is floor-correct at the boundary.** Probe: `due_occurrences(now: A+3599) == [A]` and `now: A+3600 == [A, A+3600]` (`schedule.rb:263-264`). The limit truncates from the **oldest** end (`:263`), asserted at `test/scheduler_due_occurrences_test.rb:53-62`.
- **`misfire_selection` is total over its declared enum.** `:skip|:latest|:fire_once` → latest only; `:replay` → oldest-first up to `misfire_limit` (`schedule.rb:133-143`). The enum is validated (`:294`), so no `nil` branch is reachable.
- **Defect — `max_concurrency: 0` silently disables a schedule.** `validate_limit!` accepts `0` (`schedule.rb:380`), and `overlap_decision` under `:allow` is `non_terminal >= max_concurrency ? :skip : :materialize` (`:163`). Probe: for `overlap_policy: :allow, max_concurrency: 0`, `overlap_decision(non_terminal: 0, pending: 0) == :skip` while `max_concurrency: 1` gives `:materialize`. A schedule constructed this way is **permanently undeliverable with no error and no signal** — it is the same terminal state as a healthy `forbid` backpressure skip. This is a *new* finding (F05-COR-01). `validate_budgets!` demonstrates the codebase's own idiom for this class: `budgets.max_steps` must be `positive?` (`:410`), so the constructor already knows how to reject a zero-ceiling limit; `max_concurrency` not only skips that check but *inverts* the meaning of zero.

## Lens: security and authority

Reviewed. Evidence:

- **The intersector cannot widen.** `grant_intersection` is set intersection of both keys (`grant_intersector.rb:86-91`); `removed_grant` is set difference (`:94-99`). Probe: `{read,write}` ∩ `{read}` → `{"scopes"=>["read"],"capabilities"=>[]}` with `status: :narrowed`; `{}` ∩ anything → `{}` `granted`; `nil` current → `:revoked`. The result is always a subset of the **current** policy, so a schedule can never retain removed authority at this seam. `effective_grant` returns `nil` for `:revoked` (`:57-58`), and `enforce_claim_grant` refuses the claim on `nil` (`sqlite/schedule_store.rb:259-265`).
- **`nil` policy fails closed, verified in code and test.** `normalize_values` treats a non-Hash or missing key as `[]` (`grant_intersector.rb:77-83`), which forces `:revoked`; `test/sqlite_schedule_store_test.rb:490-503` asserts `claimed.length == 0` and a `:skipped` row.
- **Wrong-typed grant is a typed refusal.** Probe: `intersect({"scopes"=>"read"}, ...)` raises `Tamoz::ConfigurationError`, not a silent `NoMethodError` (`grant_intersector.rb:79-81`).
- **The claim-time effective grant is written where the consumer can read it.** `claim_template` merges `"effective_grant" => effective` when `include_provenance` (`sqlite/schedule_store.rb:233-238`), asserted at `test/sqlite_schedule_store_test.rb:414-437`. When `include_provenance: false` (the agent session's closed-schema payload, `worker.rb:158-159`) it is left out deliberately, and the code documents why it is not lost (`:227-232`).
- **Cross-check with `FINDINGS.md` CF05-SEC-01: no overlap.** CF05-SEC-01 lives at the profile→MCP admission seam (`CapabilityBinding`/runtime builder, `analyses/mcp-profile-admission.md`). `GrantIntersector` operates on the schedule's stored maximum and the worker's current grant only; it has no MCP, profile, or egress input. Probe of the module's full export surface confirms the two inputs are `stored`/`current` and nothing else (`grant_intersector.rb:39,50`). **F05 adds no evidence toward CF05-SEC-01 and does not widen it.**
- **The fence token *is* checked on the write that matters.** `acknowledge_occurrence` predicates on `state='enqueued' AND fence = ?` (`sqlite/schedule_store.rb:496`) and raises `LeaseLostError` when zero rows change (`:502-505`). See the reliability lens for what it does *not* check.
- **Not a boundary:** `materialize_due` is reachable by any caller with a store handle, and `current_grant` is a caller-supplied keyword with no provenance check (`sqlite/schedule_store.rb:168-169`). That is correct for an internal seam (the worker supplies `@runtime.worker_grant`, `worker.rb:164`) but it means the fail-closed guarantee is only as good as the caller's honesty. Recorded as an `info` boundary note (F05-SEC-02), not a defect: no in-tree caller can supply a grant it does not itself hold.

## Lens: reliability and durability

Reviewed. Evidence, and the row's largest new findings.

- **Atomicity is real.** `materialize_due` runs the entire scan — grant gate, misfire skips, overlap decisions, request enqueue, occurrence insert — inside one `@adapter.transaction` (`sqlite/schedule_store.rb:171-197`). `test/sqlite_schedule_determinism_test.rb` proves 8 concurrent owners yield exactly 1 occurrence (1 run / 3 assertions in that test), a crash before commit leaves no partial state, and a duplicate wakeup adds none. I ran the file: **4 runs / 15 assertions / 0F**.
- **Occurrence identity cannot be duplicated by restart, dedup, or a duplicate admit.** `tamoz_occurrences.request_id` is `NOT NULL UNIQUE` and `occurrence_id` is the `PRIMARY KEY` (`migrator.rb:405-427`); the store pre-checks `occurrence_exists?` (`sqlite/schedule_store.rb:373-379`) inside the same transaction. Probe: three sequential `materialize_due` calls at the same instant yield 1 / 0 / 0.
- **A UTC-instant collision cannot duplicate delivery either.** Two schedules with the same id and instant are the same schedule; two *different* schedule ids produce different `occurrence_id`s because the id is in the digest input (`occurrence.rb:34-37`). No collision path found.
- **`materialize_due` advances no calculation state.** The contract's own comment says the scan "advance[s] calculation state under a fence" (`documentation/design/scheduling.md:43`) and the contract says it "materializes the deterministic request id" in one transaction (`schedule_store.rb:46-49`). The implementation derives due instants fresh from `start_at` on every poll (`sqlite/schedule_store.rb:240`) and has no cursor, watermark, or `anchor:` argument (probe: the store file does not contain `anchor:`; `due_occurrences`'s `anchor:` keyword at `schedule.rb:106` is dead at this call site). Correctness is preserved — `occurrence_exists?` is the real idempotence mechanism — but the "advance calculation state" property is **not implemented** and the doc sentence is unbacked. Recorded as an `info` doc/contract delta (F05-INF-03), not a correctness defect, because uniqueness at the row level already delivers the required property and AGENTS.md's "choose the simple solution" rule applies.
- **Defect — `:latest` misfire produces an unbounded durable skip ledger.** `due_occurrences` returns up to `limit` instants (`schedule.rb:263`), `misfire_selection` marks **all but the last** as `skipped` (`:138`), and `record_misfire_skips` writes one durable row per skipped instant (`sqlite/schedule_store.rb:281-288`). No maximum-age cap, no compaction, and no retention anywhere in the gem or the enumerated schema (`migrator.rb:405-427`). Probe: `due(now: A+1_000_000, limit: 10)` on a 3600s cadence yields `skipped.size == 9` per scan; with the worker's `limit: @batch` (`worker.rb:155`) each poll appends up to `batch - 1` rows. For a schedule that is continuously behind, this grows without bound while `documentation/design/scheduling.md:55` states "There is no unbounded catch-up; `misfire_limit`, maximum age, and scan batch size are finite" — **`misfire_limit` constrains only `:replay` (`schedule.rb:139-142`), is never read for `:latest`, and no maximum age exists.** This is F05-REL-04.
- **Defect — a lost consumer wedges a `forbid` schedule permanently, and no in-tree path can clear it.** Occurrences are only ever moved out of `enqueued` by `acknowledge_occurrence`, which needs the graph to produce an `execution_id` (`worker.rb:577-583`). `materialize_due` writes `fence = now_ms` (`sqlite/schedule_store.rb:442-447`) and **`lease_for` is accepted but never read** — it appears nowhere else in the file. The schema has **no expiry column** (`migrator.rb:405-427`). The store exposes no reap/reclaim/renew (probe: `respond_to?(:reap)`, `:recover_occurrence`, `:renew_occurrence_lease`, `:claim_due` → all `false`). Probe sequence: poll 1 claims and leaves the row `enqueued`; polls 2–3 at later cadences claim **0** and append `skipped` rows; an operator edit of the schedule does not help (because the occurrence key is id+revision+instant, the *next* due instant also comes under `latest` misfire-as-of-**old**-revision instant, which is also `skipped`); the ledger ends `[:skipped, :enqueued, :skipped × 7]` and never converges. `documentation/design/scheduling.md:57` promises "Concurrency is enforced from durable occurrence state" and `SCHEDULER_DESIGN.md:113` draws `lease expiry → reclaim with higher fence`, neither of which exists. This is F05-REL-05, and it is the same class as the prior CF07-ARCH-01, seen from the scheduler-contract side.
- **Prior CF07-REL-02 still reproduces, in the value object too.** `transition_from_running` accepts any `execution_id` when the state is `running` (`occurrence.rb:137-144`), and the store's completion SQL binds only `occurrence_id AND state='running'` (`sqlite/schedule_store.rb:520-528`). Probe on the **value**: `enqueued(...).running("exec-1", ...)` then `.succeeded("exec-OTHER", ...)` → `state: succeeded`, `reason: {"execution_id"=>"exec-OTHER", ...}`. The gem's own state machine, not just the adapter, permits it. See the carried-forward section.
- **Fencing is narrower than the error vocabulary implies.** `LeaseLostError` says "the occurrence lease was lost… the poller reclaims with a higher fence or moves on" (`errors.rb:21-26`) and `ClockRollbackError` says "the wall clock jumped backward far enough to be detected… the poller recomputes from durable UTC time" (`:35-41`). Neither message is reachable: no higher-fence reclaim exists, and no code path raises `ClockRollbackError` (grep of the whole gem finds it only at its definition; the store never compares clocks). Both error classes are **dead vocabulary that describes machinery this build does not have**. F05-REL-05(b), folded into that finding.

## Lens: observability and evidence

Reviewed. Evidence:

- **The two scheduler signals are registered and bounded.** `tamoz.worker.schedule.materialized` and `tamoz.worker.schedule.error` exist in the closed catalog with typed optional fields (`catalog.rb:104-113`). Correlation is an explicit **empty list** (`:106`) even though `schedule_id`, `occurrence_id` and `request_id` are carried as optional string fields — so a schedule event cannot be joined to its thread/execution by durable identity the way `tamoz.worker.request.*` can (`:95-103`). Minor observability debt: F05-OBS-06.
- **Delivery and execution evidence are genuinely distinct.** `enqueued` is never a terminal status; `TERMINAL_EXECUTION_STATUSES` excludes it and `complete_occurrence` refuses anything else (`sqlite/schedule_store.rb:509-516`), asserted at `test/sqlite_schedule_store_test.rb:531-534`. This is the "no false green" hard zero and it holds.
- **Refusals carry a durable, bounded reason.** `grant_revoked`, `misfire`, `overlap`, `coalesced`, `scan_conflict:<128-byte-truncated message>` (`sqlite/schedule_store.rb:286,335,339,407`). `scan_conflict` is truncated with `byteslice(0, 128)` (`:407`) — bounded, verified.
- **A contract-conforming adapter can fail to settle silently.** Prior CF07-ARCH-01, unchanged (see carried-forward). Not re-litigated here.
- **Gap — no signal distinguishes "deliberately skipped" from "wedged".** F05-REL-05's stuck `enqueued` row is rendered by the projection as ordinary `queued`/`enqueued` work (`worker_runtime.rb:975-993`), and F05-COR-01's `max_concurrency: 0` schedule renders as an ordinary `scheduled` phase. An operator has no signal that either is permanently dead. This is the observability half of both findings and is why they are not merely design notes.

## Lens: scalability and resource bounds

Reviewed. Evidence:

- **Scan fan-out is bounded twice.** Schedules per scan: `LIMIT ?` with the caller's `limit` (`sqlite/schedule_store.rb:180-182`). Instants per schedule: `due_occurrences(..., limit:)` (`schedule.rb:263`). Jitter offsets are bounded by `jitter_window` and derived in constant time (`:171-176`); probe confirms they land in `[0, jitter_window)` and are stable across calls.
- **Grant intersection is O(n) over two small arrays** with `uniq` normalization (`grant_intersector.rb:77-83`) — no fan-out risk.
- **Unbounded terms found (three):** (1) the `:latest`/`:skip`/`:fire_once` skip ledger, one durable row per missed instant per scan, no retention (F05-REL-04); (2) the `forbid` wedge, which converts a permanently-stuck schedule into one durable `skipped` row per cadence forever (F05-REL-05) — my probe produced 9 permanent rows in four polls and the count grows monotonically; (3) `list_occurrences` clamps `limit` to 100 (`sqlite/schedule_store.rb:562`) but appends `skipped` history forever, so the operator-visible history of a wedged schedule is itself unbounded at the storage layer even though each read is bounded. All three share one root cause: nothing in this build ever retires an occurrence row or bounds schedule history by age. Folded into F05-REL-04.
- **No backpressure seam.** `materialize_due` returns the claimed array; nothing in the contract signals "I could not keep up" other than an empty result, which is indistinguishable from "nothing was due" (F05-OBS-06).

## Lens: maintenance and architecture

Reviewed. Evidence:

- **The "never executes work" responsibility is structurally true, not a naming convention.** See the dedicated proof below. The gem's dependency closure is `tamoz-core` only (`tamoz-scheduler.gemspec:11-13`).
- **Dependency direction is honest.** `tamoz-scheduler` requires `tamoz-core` (`scheduler.rb:3`); `tamoz-sqlite` includes the contract (`sqlite/schedule_store.rb:23`); the dependency arrow points adapter → contract, never the reverse.
- **The contract is versioned and parity-tested.** `CONTRACT_VERSION = 2` (`schedule_store.rb:21`) with a deliberate v2 note (`:18-20`), and `test/scheduler_contract_test.rb` asserts both the SQLite adapter and a minimal fake expose identical keyword shapes (`:49-58`, 3 runs / 21 assertions / 0F).
- **Defect — the versioned contract omits the two operations its only real consumer needs to settle.** `acknowledge_occurrence` (`sqlite/schedule_store.rb:487`) and `occurrence_for_request` (`:541`) are not declared in `schedule_store.rb:17-77`. That is prior CF07-ARCH-01; carried forward unchanged.
- **Contract/docs mismatch — the published surface is not the implemented one.** `documentation/design/scheduling.md:34-41` still lists `claim_due`, `renew_occurrence_lease` and `enqueue_occurrence` as the contract; the shipped contract is `put_schedule`, `disable_schedule`, `enable_schedule`, `materialize_due`, `complete_occurrence`, `list_occurrences`. Three of the seven documented methods do not exist under those names or at all. F05-INF-07.
- **Value vocabulary is consistent and narrow.** `Schedule` carries 23 fields (`schedule.rb:20-41`), `Occurrence` 12 (`occurrence.rb:20-26`), the state machine is closed over 10 states with an explicit `TERMINAL` set (`:27-29`). Naming follows `validate!`/`compute_digest`/`intersect` consistently.
- **Dead surface, minor.** `Schedule#misfire_selection`'s three coinciding policies are documented as coinciding (`schedule.rb:134-137`) — honest. `ClockRollbackError` and the `LeaseLostError` "reclaim" clause are unreachable vocabulary (F05-REL-05(b)). No Ruby literals of domain knowledge were found (AGENTS.md B9 is not engaged; the gem holds no catalog/domain data).

---

## Dedicated proof: "never executes work"

The responsibility is *"Schedule and occurrence values, the store contract (never executes work)."* Verified from source, four ways:

1. **Requires.** The complete set of `require` statements in the gem is: `tamoz/core` (`scheduler.rb:3`) plus six `require_relative` lines (`:4-9`), and `require "digest"` in `schedule.rb:3` and `occurrence.rb:3`. There is no `net/http`, `open3`, `socket`, `sqlite`, `logger`, or any transport/process/IO library.
2. **Execution-shaped tokens.** A scan of all 7 lib files + gemspec for `spawn|fork|exec|system|Open3|Process\.|Thread\.new|IO\.popen|Kernel\.|sleep|eval|send\(|public_send|const_get|Net::HTTP|File\.|Dir\.|ENV\[|SQLite|puts|warn|Logger|perform|dispatch|invoke` returns **zero code matches** — every hit is inside a comment or the gemspec's description string. There are no backticks, no subshell, no `require` of anything that could perform IO.
3. **The contract contains no execution method.** All 6 methods in `schedule_store.rb:28-76` raise `NotImplementedError` in the module and are pure storage/lifecycle verbs: `put_schedule`, `disable_schedule`, `enable_schedule`, `materialize_due`, `complete_occurrence`, `list_occurrences`. `complete_occurrence` **records** a status; it takes `execution_id` and `evidence` as data (`:69`) and never invokes anything. The module's own atomicity clause (`:10-16`) is a storage promise.
4. **No dispatch surface exists to call.** Grep of all 7 lib files for `.call`, `.run`, `.perform`, and block-yielding patterns finds nothing that invokes a caller-supplied callable. The gem defines no node, worker, poller, scheduler loop, or thread. The poll loop lives in `tamoz-agent` (`worker.rb:127,147`), the transaction and enqueue primitive in `tamoz-sqlite`, and the graph execution in `tamoz-agent`/`tamoz-graph`.

**Conclusion: proven, high confidence.** `tamoz-scheduler` computes values and publishes a storage interface. It does not execute work, approve actions, retry effects, or report delivery as execution success. This is exactly what `gems/tamoz-scheduler/README.md:30-33` claims. The "never executes work" clause of invariant 38 (`invariants.md:43`) holds at this surface.

---

## Civil time: the exact boundary

Documented absence, confirmed against source:

- **Kinds shipped:** `KINDS = %i[at interval]` (`schedule.rb:42`). `:cron` is rejected with the typed message *"schedule kind must be one of [:at, :interval] (cron is a recorded deferral)"* (`:331-335`). `documentation/limitations.md:79-86` says exactly this and says a weekday-at-09:00-local schedule cannot be expressed.
- **What `at` can express:** exactly one UTC instant, canonical form `YYYY-MM-DDTHH:MM:SSZ` (`schedule.rb:355`), validated as a real calendar instant by round-trip (`:191-203`). No timezone, no offset, no local time, no date-only form, no sub-second precision. `due_at_occurrences` returns at most one instant ever (`:246-252`), asserted at `test/scheduler_due_occurrences_test.rb:97-105`.
- **What `interval` can express:** a fixed elapsed-seconds cadence from an anchor, where the anchor is `start_at || created_at` (`schedule.rb:254-256`). Expression must be a positive integer string (`:364-368`). Because the anchor is a UTC epoch second and the arithmetic is pure integer addition (`:258-265`), an interval is **immune to DST by construction** — but it also means it cannot express "every day at 09:00", "every weekday", or any civil-calendar rule at all. A 86400-second interval drifts against local wall time across a DST transition, and there is no way to say otherwise.
- **DST / timezone surface:** none. No IANA identifier field on `Schedule` (`schedule.rb:20-41` has no `timezone` member), no tz database dependency (`tamoz-scheduler.gemspec:11-13`), no local-time conversion anywhere. `documentation/design/scheduling.md:59` describes `nonexistent_local_time` handling and a `both` fold option — **neither string appears in any gem source** (grep: zero hits outside that doc line). The design paragraph describes a cron feature that is correctly declared absent at `:27` but is stated in the present tense at `:59`, which reads as shipped behavior.
- **Clock safety:** `errors.rb:35-41` defines `ClockRollbackError` for a detected backward jump, and `schedule.rb:16-19`/`occurrence.rb:9-14` argue identity makes rollback duplicates impossible (which my probes confirm — identity is instant-keyed). But nothing detects a rollback: `ClockRollbackError` is never raised, and neither `Schedule` nor the store reads a monotonic clock. A backward wall-clock jump therefore does not duplicate an occurrence (true, by identity) but also does not produce the "detected + recompute from durable UTC time" behavior the error class advertises.

**Boundary statement for the coordinator:** `at` = one absolute UTC instant, inclusive, fired at most once. `interval` = `anchor + k·N` seconds for integer `k ≥ 0`, oldest-first, truncated to the scan limit. Nothing else. There is no timezone, no civil calendar, no local time, no DST fold/gap, no cron, no event stream, no filesystem watcher, and no arbitrary trigger script.

---

## Tests and contracts

All run from `/Users/ghassan/my-projects/tamoz` with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`, one file per command. All 7 pass.

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/scheduler_values_test.rb` | 17 | 112 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_contract_test.rb` | 3 | 21 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_due_occurrences_test.rb` | 9 | 24 | 0 | 0 | 0 |
| `ruby -Itest test/scheduler_consumer_test.rb` | 8 | 26 | 0 | 0 | 0 |
| `ruby -Itest test/sqlite_schedule_determinism_test.rb` | 4 | 15 | 0 | 0 | 0 |
| `ruby -Itest test/sqlite_schedule_store_test.rb` | 21 | 73 | 0 | 0 | 0 |
| `ruby -Itest test/agent_schedule_test.rb` | 9 | 65 | 0 | 0 | 0 |

Prior-run figures for `scheduler_values_test` (17/112) and `sqlite_schedule_store_test` (21/73) in `analyses/schedule-digest-integrity.md:93-94`, and for `scheduler_contract_test` (3/21) and `agent_schedule_test` (9/65) in `analyses/occurrence-contract-and-fencing.md:116-118`, **reproduce byte-for-byte** at `582ae55`.

**What the suite does not cover** (all `not found`):

- No test asserts that `overlap_policy: :allow, max_concurrency: 0` is rejected or is deliverable → F05-COR-01 unguarded.
- No test asserts an upper bound on `:latest`/`:skip` skip-ledger growth → F05-REL-04 unguarded.
- No test exercises a lost consumer / stale `enqueued` occurrence, reclaim, or a lease expiring mid-run → F05-REL-05 unguarded. (`analyses/occurrence-contract-and-fencing.md:118-121` says the same for the CF07 row.)
- No test drives the value-level state machine with a mismatched `execution_id` (`occurrence.rb:137-144` is exercised only by the value tests for legal transitions).
- No test asserts a digest override is refused, or that a forged row cannot materialize → F05-REL-01 unguarded, as the prior report states.
- `ClockRollbackError`, `LeaseLostError`'s reclaim path, and `MisfireLimitReachedError` have **no test at all**; `MisfireLimitReachedError` is never raised anywhere in the repo (grep: definition only).
- Invariant 38/39/40 conformance as specified (`INVARIANTS.md:167-169`) is **not run**: the 50-owner race, kill-at-every-seam, DST/leap-day/timezone-change matrix, and staleness-token race are represented only by the 8-owner fake-clock test, the pre-commit-raise simulation, and no civil-time test respectively. I did not run `rake ci`/`ci_full` (prohibited by the brief).

---

## Findings

### F05-COR-01 — `max_concurrency: 0` makes an `allow` schedule permanently and silently undeliverable

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:380` (`validate_limit!` accepts `0`); `:163` (`non_terminal >= max_concurrency ? :skip : :materialize`); `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:410` (the contrasting `positive?` idiom in `validate_budgets!`) |
| Test evidence | `not found` — no test constructs `max_concurrency: 0`; `test/sqlite_schedule_store_test.rb:322-357` covers `allow(2)` and `:503-528` covers `allow(1)` only |
| Scanner signal | probe `/tmp/f05_probe3.rb` section K: `overlap_decision(non_terminal: 0, pending: 0) == :skip` for `max_concurrency: 0` vs `:materialize` for `1` |
| Independent judgment | Confirmed by direct value probe. The `allow` branch is the only policy where the cap can be zero *and* is compared with `>=`, so zero inverts "no concurrency limit" into "no concurrency ever". `forbid`/`queue_one` are unaffected. |
| Root cause | `validate_limit!` was written as one shared bounded-non-negative check for `misfire_limit`, `max_concurrency` and `jitter_window`, where `0` is legitimate for the latter two's *other* meanings (no jitter; the walk already happened). `max_concurrency` is the one limit where `0` is not a smaller budget but a different, unsatisfiable policy, and no test pins the distinction. |
| Recommendation | Reject `max_concurrency` `< 1` in `validate_policies!`/`validate_limit!` (`schedule.rb:297,379-384`) using the existing `Tamoz::ConfigurationError` path and the wording already used for budgets (`:412-413`). That is the whole fix: no new class, no new policy. Add one value test asserting `max_concurrency: 0` raises. |
| Disposition | open — recorded; a bounded constructor validation at the existing seam |

### F05-REL-04 — the `:latest` misfire ledger has no age or count bound, contradicting the "finite / no unbounded backlog" documentation

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:130-144` (`misfire_limit` read only in the `:replay` branch); `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:263` (`limit` truncates the window but does not bound history); `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:281-288` (one durable row per skipped instant, every scan); `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:405-427` (no retention/age column, no TTL); `gems/tamoz-agent/lib/tamoz/agent/worker.rb:155` (`limit: @batch`) |
| Documentation contradicted | `documentation/design/scheduling.md:55` — "There is no unbounded catch-up; `misfire_limit`, maximum age, and scan batch size are finite"; `documentation/limitations.md:80-84` — "The misfire, overlap, backlog, jitter and catch-up policies the invariant also requires ARE implemented and tested"; `docs/design-v0.1/INVARIANTS.md:95` (clause 39 requires "catch-up limit" as a stored policy) |
| Test evidence | `test/sqlite_schedule_store_test.rb:236-259` asserts the three `:skip` rows for a 4-instant window; `:444-460` asserts the four rows for `:latest`. Neither asserts a ceiling. No test exists for a long outage, ledger growth, or retention — `not found`. Runs that pass and do not cover it: `sqlite_schedule_store_test` (21/73/0F), `sqlite_schedule_determinism_test` (4/15/0F) |
| Scanner signal | probe `/tmp/f05_probe4.rb` section S: a 3600s schedule at `now = anchor + 1_000_000` with `limit: 10` yields `skipped.size == 9` in one scan |
| Independent judgment | Confirmed. The doc claim is **half true and half false**: `misfire_limit` is a real, validated, tested bound — but only for `:replay`. For the **default** policy `:latest` (`schedule.rb:53`), `misfire_limit` is never read, "maximum age" does not exist anywhere in the gem, adapter, or schema, and per-scan growth is `limit - 1`. Because the worker polls continuously with `limit: @batch`, a schedule continuously behind any plausible drain rate accumulates rows monotonically. Aggravated by F05-REL-05, where a wedged schedule emits a skipped row **per cadence, forever**. |
| Root cause (five whys) | (1) Why does the ledger grow without bound? Because every missed instant is written as its own durable terminal row with no retirement. (2) Why is nothing retired? Because there is no retention, age, or compaction seam — `migrator.rb:405-427` has no such column and the store has no delete path. (3) Why was no retention seam added? Because the design treated "the window is truncated by `limit`" (`schedule.rb:120-121`) as equivalent to "history is bounded" — the window is bounded *per scan*, and history is the sum over scans. (4) Why did the doc claim "maximum age is finite" while no maximum age exists? Because the claim was written from the design's `:replay`-centric reading of `misfire_limit`, and the three coinciding policies at `schedule.rb:134-137` were accepted as a simplification without re-checking the bound the clause requires. (5) Root cause: **invariant 39's "catch-up limit" was satisfied by one policy's parameter and then claimed for all four**, so no policy-level bound is enforced at the seam that writes the ledger. |
| Recommendation | Smallest credible action at the existing seam: make `misfire_limit` bind for the coalescing policies too — in `misfire_selection` (`schedule.rb:133-138`), cap `skipped` at `misfire_limit` and record the remainder as covered-by-coalescence rather than as individual rows; and correct `documentation/design/scheduling.md:55` to name the policy it applies to. Do not add a pruning job or a retention column (AGENTS.md: do not cover rare cases; the simple path delivers the bound). Add one store test that polls a long outage and asserts the durable row count is bounded by the schedule's own limits. |
| Disposition | open — accept as a major finding: it is a documented, invariant-39-bearing property that the code does not provide, at a named seam, with a one-line fix |

### F05-REL-05 — a lost consumer wedges a `forbid` schedule permanently: no occurrence expiry, reclaim, or recovery path exists

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` (extends prior CF07-ARCH-01 from the contract side; not a duplicate — different owning seam and different failure) |
| Source evidence | `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:17-77` (contract has no acknowledge/reap/renew/reclaim); `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:61-64` (`lease_for:` accepted); `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:168-169` (`lease_for:` never read again anywhere in the file — verified by grep); `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:442-447` (`fence = now_ms`, `state='enqueued'`, no expiry); `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:405-427` (no expiry column); `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:355-371` (`non_terminal` counts `enqueued`); `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:156-165` (`:forbid` skips while `non_terminal.positive?`); `gems/tamoz-agent/lib/tamoz/agent/worker.rb:571-587` (acknowledgement needs an `execution_id` from a graph run) |
| Documentation contradicted | `documentation/design/scheduling.md:49` ("all in ONE transaction under `owner`/`lease_for`"); `:57` ("Concurrency is enforced from durable occurrence state"); `docs/design-v0.1/SCHEDULER_DESIGN.md:107-124` (`lease expiry → reclaim with higher fence`); `docs/design-v0.1/SCHEDULER_DESIGN.md:242-249` (release gate: "stale fencing tokens" race) |
| Test evidence | `not found` for expiry/reclaim/stale-consumer. `test/sqlite_schedule_store_test.rb:303-323` covers `forbid` skipping while an occurrence is `enqueued` **in the current poll**, and never advances to a scenario where the consumer never acknowledges |
| Scanner signal | probe `/tmp/f05_probe2.rb` section I on a real SQLite temp DB |
| Independent judgment | Confirmed by reproducible probe. Poll 1 claims one occurrence and leaves it `enqueued` (published `fence = now_ms`). The consumer is then gone. Polls 2, 3, 4 at successive cadences each claim **0** and append a `skipped` row. An operator `put_schedule` edit (revision 2) does not help — the next due instant is still evaluated against the pre-edit revision's occurrence history, and the new instant under `latest` is also not the window's last, so it is skipped too. Final ledger: `[:skipped, :enqueued, :skipped × 7]`, non-converging. Probe also shows the store exposes **no** `reap`, `recover_occurrence`, `renew_occurrence_lease`, or `claim_due`, and that `complete_occurrence` from `enqueued` is correctly refused (`SchedulerError`) — so nothing in-tree can move that row. The `fence` is a published identity, not a lease: no write after enqueue checks it except `acknowledge_occurrence` (`sqlite/schedule_store.rb:496`), which is exactly the write a dead consumer cannot make. |
| Root cause (five whys) | (1) Why is the schedule stuck? Because a `forbid` schedule treats any `enqueued` row as in-flight, and the only transition out requires the consumer's `execution_id`. (2) Why can no one else clear it? Because settlement is consumer-only by design and no reconciliation path exists. (3) Why is there no reconciliation? Because `materialize_due` deliberately made claim+enqueue one atomic transaction, so the "claim" it was designed to expire never persists — but its `lease_for` parameter and the design's reclaim state were left in place as if it did. (4) Why was the stale parameter not removed or implemented? Because the simplification was accepted at implementation time (the prior audit deferred it: `docs/audits/top100-audit-2026-09-11/026-schedule_store.md:34-38`) without revising either the contract signature or the design's state diagram. (5) Root cause: **the scheduler contract advertises a lease it does not have** — `lease_for` is a public keyword, the specific-lease error class exists, and the design draws reclaim, yet no expiry is stored and no reclaimer exists. |
| Recommendation | Smallest credible action at the existing seam, in one of two directions (pick one; do not build both): **(a)** delete the lease fiction — drop `lease_for:` from `materialize_due` (`schedule_store.rb:61`), remove the reclaim clause from `LeaseLostError` (`errors.rb:21-26`), remove the unreachable `ClockRollbackError` (`:35-41`) or wire it, and revise `SCHEDULER_DESIGN.md:107-124` to the shipped atomic-enqueue model; **or (b)** honor it — since the occurrence row already stores `fence`, treat a non-terminal occurrence whose `updated_at_ms` is older than the published lease as reclaimable. Given AGENTS.md's "choose the simple solution" and "do not cover rare cases", **(a) plus one worker-side guard** is the recommended path: on the `enqueued`-with-no-live-execution case, emit a typed signal and refuse further `skipped` growth, rather than adding a reclaimer. Add a regression that polls past a lost consumer and asserts a bounded, converging ledger. |
| Disposition | open — accept as a major finding; this is the same failure family as CF07-ARCH-01 but owned by the contract's lease vocabulary rather than by the worker's settlement surface, so both stay open |

### F05-REL-01 — a schedule's canonical digest can be overridden via the constructor (carried forward from `analyses/schedule-digest-integrity.md`)

| Field | Content |
|---|---|
| Severity | `minor` (unchanged from the prior report) |
| Confidence | `high` for the constructor/store behavior; `medium` for operational impact |
| Status | **`open` — STILL REPRODUCES at `582ae55`, unchanged** |
| Re-verification | Constructor unchanged: `@digest = definition_digest \|\| compute_digest(@validated)` (`schedule.rb:69`), validation never inspects `definition_digest` (`:271-285`). Probe `/tmp/f05_probe1.rb` A: `definition_digest: "sha256:" + "0"*64` is accepted, the value differs from the canonical `sha256:aee02e22…`, and `frozen? == false`. Probe B (new): a **malformed** override (`"not-a-digest"`) is *also* accepted without error — an additional detail beyond the prior report. SQLite round trip unchanged: `put_schedule` writes `schedule.definition_digest` straight into the column (`sqlite/schedule_store.rb:87`) and `materialize_schedule` treats the stored value as authoritative without recomputation (`:699-705`). Probe `/tmp/f05_probe2.rb` H on a real temp DB: `stored_forged=true recomputed=false`. **New positive detail:** the *no-override* round trip **does** preserve the canonical digest (probe G: `put == fetch == recompute`), so the defect is strictly the override path, exactly as the prior report scoped it. |
| Why it does not escalate | Confirmed unchanged: `Occurrence.identity` excludes the digest (`occurrence.rb:34-37`) and `compute_digest` excludes it by design (`schedule.rb:79-84`), so no occurrence identity, request id, lease, or idempotence property depends on it. The CLI still offers no digest option (`cli_schedule_commands.rb:33-102`). Prior finding stands as recorded; **not re-litigated, not promoted**. |

### F05-REL-02 — completion accepts an execution id different from the acknowledged one (carried forward from CF07-REL-02)

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` for the store behavior; `medium` for an in-tree mismatched caller |
| Status | **`open` — STILL REPRODUCES, and is broader than the prior report recorded** |
| Re-verification | Prior report cited the SQLite completion predicate (`sqlite/schedule_store.rb:520-528`) and the value state machine (`occurrence.rb:82-101,137-144`). Both are unchanged. **New evidence:** the *value* object alone, with no store involved, accepts the mismatch — probe `/tmp/f05_probe1.rb` E: `claimed(fence: 111) → enqueued → running("exec-1") → succeeded("exec-OTHER", …)` yields `state: succeeded`, `reason: {"execution_id"=>"exec-OTHER", …}`. So the omission is in the gem's own state machine, not only in the adapter's SQL — which places a share of this finding inside **this** row's surface rather than only in F07's. Probes D/F also confirm the state machine preserves `fence` and `owner` across `running` but overwrites `reason` with the execution id (`occurrence.rb:85`), which is what makes the recorded execution identity the sole evidence of which run terminated. |
| Recommendation (delta to the prior one) | The prior recommendation is right and complete for F07: compare the recorded execution id in the completion transaction. Add the value-level half at *this* row's seam — have `transition_from_running` refuse when `reason["execution_id"]` is present, is a String, and differs from the supplied `execution_id` (`occurrence.rb:137-144`), raising the existing `SchedulerError`. That is a two-line guard in the owner of the state machine. |

### F05-INF-03 — `materialize_due` does not advance calculation state, though the doc says it does (info)

`documentation/design/scheduling.md:43` and `docs/design-v0.1/SCHEDULER_DESIGN.md:236-237` describe claim-time advance of calculation state under a fence; the implementation derives due instants fresh from the anchor every poll (`sqlite/schedule_store.rb:240`) and keeps no cursor (probe: `anchor:` never appears in the store). Correctness holds because `occurrence_exists?` (`:373-379`) plus the `PRIMARY KEY`/`UNIQUE` constraints are the real idempotence mechanism. Severity `info`: the simple solution already delivers the property; **recommend nothing** beyond correcting the doc sentence.

### F05-INF-07 — the published `ScheduleStore` contract in `documentation/design/scheduling.md` names three methods that do not exist (info)

`documentation/design/scheduling.md:34-41` lists `claim_due`, `renew_occurrence_lease` and `enqueue_occurrence`. The shipped contract (`schedule_store.rb:17-77`) is `put_schedule`, `disable_schedule`, `enable_schedule`, `materialize_due`, `complete_occurrence`, `list_occurrences`. `test/scheduler_contract_test.rb` guards the shipped surface; nothing guards the doc. Severity `info` — a documentation-consistency item at the same seam as F05-REL-05's recommendation (a). Relatedly, `documentation/design/scheduling.md:59` states DST fold/gap handling in the present tense, while `documentation/limitations.md:79-86` correctly declares it absent; the limitations page is the accurate one.

### F05-OBS-06 — schedule signals carry an empty correlation list and cannot distinguish backpressure from a dead schedule (minor)

`catalog.rb:104-113` registers `tamoz.worker.schedule.materialized` and `tamoz.worker.schedule.error` with `correlation: []`, while the sibling `tamoz.worker.request.*` events correlate on `thread_id` and `occurrence_id` (`:95-103`) — even though `schedule.materialized` carries `schedule_id`, `occurrence_id` and `request_id` as optional fields (`worker.rb:167-172`). Consequence: F05-REL-05's permanently-stuck occurrence and F05-COR-01's dead schedule present identically to healthy backpressure (`worker_runtime.rb:975-993` renders both as ordinary `queued`/`scheduled`), with no signal an operator can alert on. Root cause is mechanical: the two events were added with the field set and without the correlation list. Recommendation: add `%i[occurrence_id]` to the materialized event's `correlation` (the value is already passed) and emit the stuck-occurrence condition once per schedule rather than only as a low-cardinality `reason` string. Confidence `high`, status `open`, severity `minor`.

### F05-SEC-02 — `current_grant` is a caller-supplied keyword with no provenance check (info)

`materialize_due(current_grant:)` (`schedule_store.rb:52-55,61-63`) is the invariant-40 fail-closed input, and the implementation trusts it absolutely (`sqlite/schedule_store.rb:259-265`). The in-tree caller supplies `@runtime.worker_grant` (`worker.rb:164`), which is derived from the operator policy, so no widening is reachable today. Recorded as a verified boundary fact, not a defect: the fail-closed guarantee is a property of the caller's honesty, not of the seam. Confidence `high`, severity `info`.

### Status of prior CF07-ARCH-01 (carried by name, not re-litigated)

**`open` — unchanged.** `acknowledge_occurrence` (`sqlite/schedule_store.rb:487`) and `occurrence_for_request` (`:541`) remain absent from the versioned contract (`schedule_store.rb:17-77`), the worker still guards with `respond_to?` (`worker_runtime.rb:493`), and settlement still returns silently on `nil` (`worker.rb:571-587`). `test/scheduler_contract_test.rb:15-29` still implements exactly the declared methods, and `:49-58` still checks only those. F05-REL-05 is the same public-interchangeability defect seen from the scheduler contract's side; the two are recorded as distinct findings at distinct seams and neither duplicates the other.

---

## Blind spots

- **Row F07 owns `gems/tamoz-sqlite`.** I read `sqlite/schedule_store.rb` (737 lines) and `migrator.rb:405-435` in full as this row's implementation and cite them, but I do not claim F07 coverage: I did not review the adapter's transaction implementation, the checkpoint codec, `enqueue_request_in_transaction!`, or the rest of the migrator. F05-REL-04/05 recommendations land in that file and need F07 to accept them.
- **`gems/tamoz-agent` is row F25.** I traced `worker.rb` schedule paths and `worker_runtime.rb`'s projection only far enough to establish the caller contract. I did not review worker lifecycle, leases elsewhere, approval, or the durable runner.
- **`tamoz-evals` verification of the contract.** `documentation/design/scheduling.md:31` says the SQLite implementation is "verified by `tamoz-evals`". `test/scheduler_consumer_test.rb` (8/26/0F) tests a read-only scorecard-summary *consumer*, not a contract verifier; `gems/tamoz-evals-runner/lib/tamoz/evals/runner/scorecard_summary_consumer.rb:22` explicitly disclaims being a ScheduleStore job. **Not found**: no evals-side ScheduleStore conformance harness. I did not search `tamoz-evals` exhaustively — flagged as a lead for whoever owns F26/F27.
- **`test/support/agent_smoke_corpus.rb:2420-2475` and `test/agent_scorecard_test.rb:336-354`** encode a schedule materialization case with six named proofs. I read the assertions, not the corpus construction; I did not run `agent_scorecard_test.rb` (heavier, and its schedule case is already covered by the suites I did run).
- **Multi-process contention was not exercised.** `test/sqlite_schedule_determinism_test.rb` uses 8 owners in **one** process against one connection; the invariant-39 shape (50 owners) and cross-process SQLite locking were not run. `not run`.
- **Clock rollback / monotonic-clock behavior was reasoned from source and value probes, not simulated** with a fake wall clock; there is no injectable clock at the store seam (`sqlite/schedule_store.rb:601-603` uses `Time.now` directly).
- **No real provider execution, no subprocess, no network was exercised** (out of scope and prohibited).
- **`rake ci` / `rake ci_full` not run** (prohibited by the brief); no RuboCop/Reek/SimpleCov/Enola result is claimed.
- **Proven vs. lead:** every finding above cites source I read plus a probe I ran. The only lead-shaped item is the missing evals-side conformance harness, which I recorded as a blind spot rather than a finding.

---

## Verdict

**IMPROVE** — per BAR.md: at least one accepted critical/major finding.

- Critical: **0**
- Major: **2** (F05-REL-04, F05-REL-05) + **1 carried forward** (F05-REL-02)
- Minor: **3** (F05-COR-01, F05-OBS-06, F05-REL-01 carried forward)
- Info: **3** (F05-INF-03, F05-INF-07, F05-SEC-02)

Six-lens status: correctness **reviewed**, security/authority **reviewed**, reliability/durability **reviewed**, observability/evidence **reviewed**, scalability/resource bounds **reviewed**, maintenance/architecture **reviewed**. No lens is `not evidenced`.

Row-specific conclusions requested by the brief:

1. **"Never executes work" — proven, high confidence.** Zero execution surface in the gem by requires, token scan, contract shape, and absence of any dispatch seam. The responsibility is structurally true, not a naming convention.
2. **Occurrence identity and idempotence — sound for the value, and sound end to end for the shipped path.** Identity is deterministic from `(schedule_id, schedule_revision, nominal_fire_at_utc)`, jitter-independent, digest-independent, and protected by `PRIMARY KEY` + `UNIQUE` plus an in-transaction existence check. No duplicate path found from clock skew, restart, UTC collision, or a duplicate admit.
3. **Lease/fence semantics — the fence is checked where it can be, and the lease does not exist.** `acknowledge_occurrence` CASes on `fence` and raises `LeaseLostError`; `complete_occurrence` does not check the fence and does not bind the execution id. `lease_for` is never read, no expiry is stored, no reclaim exists, and a lost consumer wedges a `forbid` schedule permanently (F05-REL-05). Two consumers cannot hold one occurrence *simultaneously* (the fence CAS serializes them), but one dead consumer holds it forever.
4. **Misfire / overlap / backlog / jitter / catch-up — implemented and tested, but the "finite" half of the doc claim is false for the default policy.** All four misfire policies, all three overlap policies, deterministic jitter, and overlap-from-durable-state are real and tested (`sqlite_schedule_store_test.rb:236-397`, `sqlite_schedule_determinism_test.rb`). `misfire_limit` bounds only `:replay`; "maximum age" does not exist; the `:latest` ledger grows per scan (F05-REL-04). Partial contradiction of `documentation/limitations.md:80-84`; the civil-time half of that page is accurate.
5. **Civil time — the documented absence is correct.** Kinds `:at` and `:interval` only; `:cron` rejected with a typed message. `at` = one absolute UTC instant; `interval` = `anchor + k·N` seconds, anchor = `start_at || created_at`. No timezone, no local time, no DST handling, no cron. `documentation/design/scheduling.md:59` states the DST contract in the present tense and does not match `limitations.md`.
6. **Grant intersection — cannot widen authority.** Set intersection with the **current** policy is always the result; `nil` policy fails closed; `:revoked` refuses the claim. It intersects scopes and capability names only, at claim time and (via the agent's session re-binding) at execution. **Cross-check with CF05-SEC-01: no overlap** — that finding lives at the profile→MCP admission seam with no scheduler input.
