# M3.1 plan — persistence evidence closure

Status: accepted for implementation after adversarial review on 2026-07-30.

Depends on:

- M3 plan `2472cfe`
- M3 runtime `ae27b96`
- M4 plan `e15b1f8`

M4 implementation is blocked on an upstream RubyLLM release. M3.1 uses that wait to close
the durability evidence gaps explicitly recorded by the M3 review. It changes no public
runtime semantics unless a harness exposes a correctness defect; any such defect receives
its own root-cause review and regression test.

## Outcome

M3.1 produces reproducible evidence for:

- trace-derived real-process `SIGKILL` at every named persistence hook;
- request, lease, checkpoint, effect, Store, prune, tombstone, purge, backup, and migration
  old-or-new atomicity;
- multi-process duplicate delivery, FIFO, fencing, and stale-writer rejection;
- bounded `SQLITE_BUSY`, `SQLITE_FULL`, permission, corruption, and schema faults;
- connection, file descriptor, thread, RSS, and WAL soak behavior;
- named-machine latency distributions against a direct SQLite baseline;
- six public `m3.persistence` evaluation cases under OS-denied network;
- Ruby 3.3, 3.4, and 4.0 CI evidence.

M3.1 is evidence closure, not a new feature milestone. It adds harnesses, public evaluation
artifacts, and review records. The production diff should be zero unless a failing treatment
proves a defect.

## Evidence claims and proof

| Claim | Authoritative evidence |
|---|---|
| transaction is atomic under process death | child receives `SIGKILL`; independent process reopens and matches complete old/new reference state |
| successful task is not re-executed | independent synchronous call ledger has one logical invocation after recovery |
| fence excludes stale owner | independent processes race/take over; stale writer's SQL changes remain zero |
| request has one execution binding | concurrent duplicate delivery plus raw row/transition inspection |
| unsafe ambiguity stops | independent target ledger plus effect attempt/transition rows show zero automatic redispatch |
| backup is a consistent publication | concurrent writer workload, backup API, destination integrity and logical snapshot check |
| bounded under contention | elapsed monotonic time and retry/checkout instrumentation remain within declared envelope |
| no resource leak | before/after named metrics with warmup, GC policy, tolerance, and retained-resource attribution |
| performance target | raw samples and p50/p95/p99 on named hardware, Ruby, SQLite, filesystem, state size, and durability pragmas |
| public eval result is valid | `Tamoz::Evals.verify`, pinned case/result digests, fixed test selections, OS sandbox self-test |
| supported Rubies work | clean CI jobs on 3.3, 3.4, and 4.0 for the exact commit |

An exception-injection unit test is useful diagnostic evidence, but it cannot satisfy a
process-death claim. A successful GitHub job on a different revision cannot satisfy the
matrix claim.

## Trace-derived kill matrix

Handwritten kill-point lists drift. The harness first runs each scenario with a recorder
and obtains its ordered hook trace:

```text
scenario
operation
point
statement (when present)
attempt
occurrence
```

The first slice adds a versioned durable-boundary registry adjacent to the persistence
implementation and compares it with observed hooks. Every public persistence operation
declares the transaction, statement, file, and publication boundary labels it can reach.
The file-mutating primitives are routed through instrumented wrappers, and a structural
contract test rejects direct uses outside those wrappers. The registry is still a reviewed
design artifact—not a proof that arbitrary Ruby was discovered automatically—but it makes
omission visible in both code review and executable coverage.

M3 currently has blind spots around initial database-file creation/permission publication
and backup temporary-file creation. M3.1 may add metadata-only internal hooks and wrappers
at those exact boundaries; this is the only anticipated production change absent a
correctness failure. Hook metadata is versioned, contains bounded public labels rather than
raw payloads or paths, and remains an internal testing/observability contract.

Hooks include:

```text
before_begin / after_begin
before_sql / after_sql
before_commit / after_commit
before_backup_step / after_backup_step
before_backup_publish / after_backup_publish
before_file_create / after_file_create
before_file_mode / after_file_mode
```

The trace is canonical JSON and digest-pinned. Coverage identity is the semantic tuple of
scenario, operation, point, statement, attempt class, and bounded iteration class—not an
unbounded runtime occurrence number. Fixed fixtures classify repeated backup/retry hooks as
first, middle, final, or exhausted where those states differ. A configured maximum rejects
an unexpectedly growing trace instead of silently expanding the release matrix.

For every reachable coverage identity, the harness:

1. creates an isolated same-filesystem temporary directory;
2. establishes the scenario's committed setup state;
3. starts a fresh Ruby child with one exact kill selector;
4. has the child write and `fsync` a separately opened control record, notify the parent,
   and block at the selected hook;
5. has the parent validate the exact selector and send `SIGKILL` while the child remains
   blocked;
6. starts a different Ruby process with no inherited adapter;
7. runs SQLite integrity/foreign-key checks and scenario observation through an independent
   raw-SQL/reference projector that does not call the production transition being tested;
8. compares observation against explicitly allowed complete old/new states;
9. runs scenario-specific recovery and convergence checks;
10. records hook, exit signal, observed state, recovery state, timing, and artifact digests.

Selectors are deterministically shardable by scenario/hook digest. A release merge checks
that shard manifests are disjoint, cover the complete traced manifest, and use the same
subject revision and harness digest. Busy/retry error paths have their own recorded traces;
the successful trace is not assumed to enumerate them.

The control record must be written and `fsync`ed before the parent kill without sharing the
SQLite transaction. It contains no database payload or secret. It proves coverage, not
database correctness. Missing/unfired selectors, selector mismatches, child progress beyond
the selected hook, and timeout all fail the matrix. Hook metadata records transaction
attempt only when the production hook supplies it; the semantic coverage identity never
assumes it.

### Scenarios

The release profile covers:

- database creation and every migration statement;
- lease acquire, validate, renew, release, expiry, and takeover;
- request enqueue, duplicate, claim, running, redirect pin, recovery, completed, and failed;
- checkpoint start, advance, turn, fork, pause, fail, complete, task-write append, and
  activation consumption;
- effect prepare, start, late complete, retry decision, unknown, reconcile, human resolve,
  and deletion abandonment;
- Store create/update/delete CAS;
- prune;
- tombstone and purge;
- backup stepping and publication.

Some hooks share one storage implementation, but coverage remains scenario-specific because
the allowed old/new state and recovery oracle differ.

## External effect treatments

The effect matrix uses a separate SQLite target ledger opened without Tamoz code, with
`synchronous=FULL`, integrity checks, and its own old/new target oracle. It records:

- stable effect key;
- attempt token;
- target invocation id;
- safety class;
- started/completed markers;
- deterministic result;
- optional idempotency-key uniqueness.

It is intentionally outside the Tamoz database. Reopening Tamoz cannot rewrite target truth.
Killing during the target transaction may leave the complete old or new target state; a
partial ledger row is invalid evidence.

Treatments:

- read-only and idempotent target;
- transactional local target with queryable receipt;
- reconcilable target with lookup;
- unsafe target with no lookup.

For each, kill before prepare, after prepare, after start, during target, after target success,
after receipt, after task write, and before checkpoint. Assertions follow the M3 safety table.
The unsafe treatment has a hard zero on automatic second target invocation.

## Multi-process races

All race participants construct their own adapter after process start. A pipe barrier aligns
the contested action without sharing writable connections.

Required races:

- two and eight owners acquire one namespace;
- expiry/takeover while the old process delays a task write and checkpoint;
- 2, 8, and 32 concurrent duplicate request enqueues;
- distinct request enqueues with FIFO observation;
- old/new effect attempts deliver receipts in both orders;
- tombstone against live lease and late exact receipt;
- Store CAS with one expected version;
- backup during a bounded writer workload.

Results are read from child pipes/files only after exit and verified against database rows by
an independent process. Scheduling order is never asserted; invariants are.

## Storage fault treatments

### Busy/locked

Hold a real `BEGIN IMMEDIATE` writer on an independent connection. Measure adapter failure or
success against one total operation deadline. Assert retries do not multiply busy,
checkout, and operation timeouts.

### Full

Use a dedicated temporary database and constrained `max_page_count` after setup. Fill pages
until SQLite reports full, execute a Tamoz action, reopen, and verify the prior complete
state. The test never fills the host filesystem.

### Permissions and paths

Test mode, parent write denial where supported, symlink source/destination, non-regular file,
URI filename, ownership check where available, WAL/SHM mode, and explicit repair. Platform
unsupported cases report skip rather than pass.

### Corruption and versions

Treat:

- checkpoint, request, effect, Store, tombstone, and deletion-receipt digest mismatch;
- truncated canonical JSON and BLOB;
- foreign-key violation in a copy with checks disabled, then verification;
- wrong application id, checksum, older fixture, and newer `user_version`;
- duplicate keys, deep nesting, invalid UTF-8, oversized payload, unknown enum/version.

Corruption tests operate on disposable copies and never use the result as a recovery source.

## Resource soak

Two profiles:

- PR: 1,000 operations, intended to catch fast regressions;
- release: 10,000 short sessions plus 10,000 Store/history enumerations and repeated
  open/close/backup cycles.

Record:

- process RSS from the operating system;
- live Ruby threads and Tamoz lease-renewal threads;
- open file descriptors from `/proc` or `lsof` fallback;
- pool available/checked-out counts;
- SQLite statement and database objects where observable;
- database, WAL, and SHM sizes;
- GC count, heap live slots, and allocated objects.

Method:

1. fixed warmup;
2. full GC and baseline;
3. bounded workload with deterministic seed;
4. early-break enumerations and injected errors;
5. close every adapter;
6. WAL checkpoint where safe;
7. full GC and repeated retained measurements.

Hard gates:

- zero checked-out connections;
- zero live renewal threads;
- no monotonically growing FD series;
- WAL returns below a declared page bound after checkpoint/close;
- retained RSS/heap is reported with tolerance, not required to return byte-for-byte;
- every nonzero retained resource has an owner attribution.

## Performance evidence

Performance never runs inside correctness assertions and never weakens `WAL`,
`synchronous=FULL`, digest verification, or fsync behavior.

Benchmark cases:

- direct SQLite `BEGIN IMMEDIATE` + insert + `COMMIT` baseline;
- small Store CAS;
- small checkpoint synchronous commit;
- durable request turn with deterministic no-op node;
- resume from 500 checkpoints;
- online backup of a named-size database.

Record:

- exact Git commit and dirty state;
- OS/kernel, CPU, memory, filesystem/mount, storage device where discoverable;
- Ruby, Bundler, sqlite3 gem, and SQLite library versions;
- pragma values;
- state and database bytes;
- warmup, sample count, raw monotonic samples;
- median, p50, p95, p99, min/max;
- allocated objects and retained heap;
- direct-baseline ratio.

Targets from M3 remain `<10 ms p95` small synchronous commit and `<50 ms p95` resume from
500 checkpoints on the named local SSD. A miss is reported, never hidden by threshold edits.
Results from virtualized/shared CI are informational.

## Public `m3.persistence` evaluations

Six source-controlled cases:

1. `m3.atomic-checkpoints`
2. `m3.fenced-requests`
3. `m3.effect-ambiguity`
4. `m3.store-backup-deletion`
5. `m3.kill-fault-recovery`
6. `m3.resource-performance`

The sixth case hard-gates resource ownership and artifact completeness. Hardware latency
thresholds are hard gates only on a named reference-runner profile; ordinary CI records
performance as informational evidence so shared-runner noise cannot create a false
correctness failure.

The fixed runner:

- accepts only one output directory;
- contains a constant case-to-test/harness selection;
- rejects a dirty tree unless an explicit test-only override is set;
- self-tests OS network denial and execution deadline;
- clears ambient Bundler/Ruby injection variables;
- executes each selection in a new process;
- captures bounded stdout/stderr;
- records exact revision/tree, platform, Ruby/SQLite versions, seed, timings, and component
  digests;
- replaces temporary roots, usernames, host-specific paths, and database identities with
  bounded public labels before artifact creation;
- emits canonical evidence and result artifacts;
- verifies every result before reporting success.

Release results must be produced from a clean commit. Performance references may target the
immediately preceding code commit when the only later diff is the generated reviewed report.

## Ruby version matrix

The repository already declares Ruby 3.3, 3.4, and 4.0 in pinned GitHub Actions. M3.1 adds:

- a test that the matrix and gem requirements agree;
- exact sqlite3 platform/source resolution checks;
- a clean-process installed-gem smoke on every matrix entry;
- uploaded bounded test/evidence summaries for diagnosis.

This workstation currently has only Ruby 3.3.11. Local green evidence must not be described
as 3.4/4.0 evidence. Without authorization to push or install additional Rubies, those jobs
remain an explicit external release gate.

## Implementation slices

1. Evidence schema and shared subprocess harness.
2. Trace recorder and checkpoint/request/lease kill scenarios.
3. Effect target ledger and ambiguity matrix.
4. Store/deletion/backup/migration kill scenarios.
5. Multi-process races and storage faults.
6. Resource soak and performance reporter.
7. Public M3 cases, fixed runner, verifier tests, and package manifest.
8. Final cross-slice review, full local gate, and clean-revision evidence run.

Each numbered slice is a phase. Before the next slice starts, its complete diff receives a
deep self-review, focused and full regression gates pass, the review record is updated, and
the slice is committed atomically. Generated evidence is never mixed into the code commit.
Production changes require a named failing treatment, root cause, regression test, and
review entry. A final reviewed report may be committed only after evidence is generated
from the exact clean subject revision.

## Review gate

Implementation begins only if every answer is yes:

- Does every broad claim map to a stronger direct observation rather than a proxy?
- Is every reachable named hook discovered from execution rather than maintained by hand?
- Does each kill occur in a child with independent reopen verification?
- Can the harness prove the requested selector fired?
- Are old/new states enumerated per scenario and partial states rejected?
- Is external effect truth outside the Tamoz database?
- Do unsupported platform checks skip explicitly rather than become false passes?
- Are time, bytes, processes, output, retries, samples, and artifacts bounded?
- Does the soak distinguish hard resource ownership from noisy RSS behavior?
- Does performance preserve production durability settings and publish raw samples?
- Are public eval selections fixed and network denial self-tested?
- Does the Ruby matrix claim only jobs actually executed on the exact revision?
- Can harness code itself accidentally access credentials, network, production paths, or a
  real external effect?
- Are M4 and M5a implementation still untouched?

Any “no” revises this plan before harness implementation.

## Plan review result

Accepted. [M3_1_EVIDENCE_PLAN_REVIEW.md](reviews/M3_1_EVIDENCE_PLAN_REVIEW.md) records the
adversarial review, resolved critical/high findings, Five Whys analyses, implementation
acceptance conditions, and external evidence gates.
