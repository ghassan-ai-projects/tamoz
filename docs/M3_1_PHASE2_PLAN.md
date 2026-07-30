# M3.1 phase 2 plan — trace-derived checkpoint, request, and lease kills

Status: accepted for implementation after adversarial review on 2026-07-30.

Process amendment on 2026-07-30: each implementation slice below is independently
reviewed, regression-tested, and committed before the next slice begins. This supersedes
the original single-commit phase rule. Phase 2 still receives one final cross-slice review
before it is called complete.

Depends on:

- reviewed M3.1 plan `5670f11`;
- reviewed phase 1 evidence foundation `2611f70`;
- implemented M3 SQLite runtime `ae27b96`.

Phase 2 implements the first trace-derived real-process kill slice. It covers lease,
request, pending-write, and checkpoint transactions. It does not claim complete M3
persistence coverage: effects belong to phase 3; Store, deletion, backup, and migration
belong to phase 4; real busy/retry paths and storage faults belong to phase 5.

## Outcome

At the phase boundary Tamoz has:

- a versioned, source-audited durable-boundary registry;
- versioned, bounded hook metadata with transaction attempts on statement hooks;
- deterministic traces and semantic kill selectors;
- a parent-controlled `SIGKILL` handshake proving the exact selector fired;
- fixed checkpoint, request, and lease scenario drivers;
- an independent raw-SQL oracle that classifies reopened state as complete old, complete
  new, stable, partial, or invalid without loading Tamoz;
- PR sentinels and a deterministically shardable release matrix;
- canonical phase 1 evidence envelopes for every retained run;
- regression coverage for the existing crash-recovery behavior.

No new public runtime API is introduced. Hook, registry, trace, and scenario types remain
internal. Runtime semantics change only if a real kill treatment exposes a separately
reviewed correctness defect.

## Current-state evidence

The implementation starts from these observed facts:

- `DatabaseKernel` emits `before_begin`, `after_begin`, `before_commit`, and `after_commit`
  with operation and attempt.
- `Transaction` emits `before_sql` and `after_sql` with operation and statement, but not
  attempt or metadata version.
- checkpoint/request SQL goes through `Transaction`; lease SQL goes through
  `LeaseOperations` and `Transaction`.
- current crash tests self-kill at two checkpoint commit points and do not prove the
  requested selector fired independently.
- the phase 1 subprocess schema permits only timeout-driven termination. Intentional
  selector kills therefore need a distinct termination reason before they can become valid
  evidence.
- this slice has no database-file or backup-file boundary. File wrappers and file hooks
  remain phase 4 work and cannot be claimed by phase 2.

## Non-negotiable invariants

1. A runtime trace cannot prove that an uninstrumented boundary does not exist.
2. A registry entry without a reachable trace is missing evidence, not coverage.
3. An observed hook without a registry entry is a hard failure.
4. Selector identity contains no SQL, bind, payload, path, process id, or timestamp.
5. The child never decides that its own death proves coverage.
6. The parent validates a separately fsynced control record before sending `SIGKILL`.
7. The post-kill oracle runs in a different process with no inherited adapter.
8. The independent oracle loads `json`, `digest`, and `sqlite3`, but no Tamoz gem.
9. A statement kill inside an uncommitted transaction must reopen as the complete old
   state; `after_commit` must reopen as the complete new state.
   An intentionally idempotent/read-only action may instead have one explicitly declared
   stable state on both sides.
10. No recovery call runs until the independent old/new/stable classification succeeds.
11. A dirty tree may run test-only evidence, but release evidence binds a clean exact
    revision and tree.
12. Phase 2 makes no effect, Store, deletion, backup, migration, retry-path, soak, or
    performance claim.

## Versioned durable-boundary registry

`tamoz-sqlite` receives one deeply frozen internal registry with:

```text
registry_version
operation
statement template
access: read | write
phase owner
kill_required
max_instances
```

The registry is data, not a second execution engine. It never selects SQL or changes a
transaction. Its canonical digest is computed with a Tamoz SQLite-specific domain.

Phase 2 registers all transaction operations and statement templates in
`checkpoint_store.rb` and `lease_operations.rb`. Deferred operations such as
`checkpoint.prune` are present with their owning phase and `kill_required: false` until
that phase lands. Dynamic labels are permitted only as reviewed templates:

```text
checkpoint.writes.item.{index}
checkpoint.commit.consume.{index}
{lease-context}.thread
{lease-context}.row
```

Arbitrary interpolation is rejected. Every template has a fixed maximum expansion count;
an observed index/count outside that bound fails instead of growing the manifest.
`lease-context` is not free text: the registry enumerates every allowed call-site expansion.

Registry ownership is explicit:

| Owner | Operations |
|---|---|
| phase 2 lease | `lease.acquire`, `lease.validate`, `lease.renew`, `lease.release` |
| phase 2 request | `request.enqueue`, `request.claim`, `request.recover`, `request.redirect_ready`, `request.transition` |
| phase 2 checkpoint | `checkpoint.append_writes`, `checkpoint.commit` |
| phase 4 deferred | `checkpoint.prune` |
| source-audited accessors | `checkpoint.latest`, `checkpoint.find`, `checkpoint.history`, `checkpoint.pending`, `checkpoint.pending_writes`, `request.fetch` |

A structural audit uses `Ripper`, not a text-only regular expression, to extract transaction
operation literals and statement literal/templates from the two source files. It fails on:

- a source label absent from the registry;
- a registry label absent from source;
- an unreviewed interpolated label;
- direct `SQLite3::Database`, `connection.execute`, or filesystem mutation in those
  capability files;
- a phase 2 `kill_required` operation that has no fixed scenario.

Runtime trace coverage then checks operation-to-label reachability. The static audit and
runtime trace are separate evidence; neither substitutes for the other.

## Hook metadata v1

Every transaction/statement hook emits a deeply frozen object:

```json
{
  "hook_version": 1,
  "kind": "transaction",
  "operation": "checkpoint.commit",
  "statement": null,
  "attempt": 1
}
```

Statement hooks use `kind: "statement"` and their bounded statement label.
`DatabaseKernel#read` uses `attempt: null`; every `DatabaseKernel#transaction` block
propagates its integer attempt even when the scenario is logically read-only. The fixed
keys are always present.

Hook validation rejects:

- unknown versions, kinds, points, operations, or statements;
- attempts other than null or a positive integer;
- statement metadata without a statement or transaction metadata with one;
- values outside the identifier/byte bounds;
- registry/operation mismatches.

The default no-op injector keeps the existing runtime cost to bounded object construction
and one callable invocation. Registry audits do not run on production calls.

## Trace and selector model

A trace event contains only:

```text
sequence
scenario
point
hook_version
kind
operation
statement
attempt
occurrence
```

The recorder hard-limits events per scenario, operations, statement labels, attempts, and
occurrences. It fails rather than truncates. Its canonical manifest binds:

- scenario version/digest;
- boundary-registry version/digest;
- ordered events;
- derived selectors;
- subject revision/tree and dirty state;
- recorder version/digest.

A selector is:

```text
scenario
point
operation
statement
attempt_class
occurrence
iteration_class
selector_digest
```

`occurrence` is the concrete child target. `iteration_class` replaces unbounded repetition
with `single`, `first`, `middle`, or `final`; `attempt_class` has the separately bounded
`first`, `retry`, and `exhausted` vocabulary. Phase 2 fixtures have bounded write/consume
counts and no unbounded loop. Duplicate coverage identities are rejected.

The Phase 2B recorder is disarmed during bootstrap, binds to exactly one Phase 2
kill-required operation and the arming thread, and accepts one complete first-attempt
protocol:

```text
before_begin
after_begin
(before_sql, after_sql)+
before_commit
after_commit
```

Hook input must be deeply frozen and is copied into recorder ownership. Dynamic statement
indices are zero-based, contiguous, and bounded by both the registry and the 256-event
scenario ceiling. Selector groups retain `first`, the lower-median `middle`, and `final`
representatives, then sort by the domain-separated selector digest.

The manifest verifier preflights all container, scalar, string, integer, event, and selector
bounds before canonicalization. It verifies the manifest digest and exact recorder/registry
references, replays the ordered events through a fresh recorder, re-derives selectors, and
requires byte-semantic equality with the supplied manifest.

Successful traces use `attempt_class: first`. The data model supports `retry` and
`exhausted`, but real locked-writer traces are owned by phase 5. Phase 2 artifacts must
report those paths as out of scope rather than implying they were observed.

## Intentional termination semantics

Phase 1's process result is extended with:

```text
termination: none | term | kill
termination_reason: none | timeout | intervention | cleanup
timed_out: true | false
```

Relations:

- `timed_out` is true exactly for `termination_reason: timeout`;
- `termination_reason: intervention` requires a configured parent intervention;
- selector evidence requires `termination: kill`, `termination_reason: intervention`,
  `term_signal: KILL`, and `timed_out: false`;
- cleanup termination is never successful evidence;
- ordinary successful execution requires both termination fields to be `none`.

The subprocess runner polls a bounded intervention object while waiting. It retains any
`WUNTRACED` stopped status and passes only the stop-signal name plus monotonic remaining
budget to the intervention—never a raw process id. The object may return only `nil` or the
fixed `kill` decision. Exceptions cause bounded child cleanup and an infrastructure
failure. Raw process ids are never returned or serialized.

## Parent-controlled kill handshake

For one selector:

1. Parent creates a private same-filesystem directory and an absent control path.
2. Parent starts a fresh child with an exact environment and fixed scenario/selector.
3. Child constructs its adapter after process start.
4. The fault callback counts validated hook occurrences.
5. On the exact match, the child creates the control file with `O_EXCL` and mode `0600`.
6. Child writes canonical selector and observed-hook metadata, flushes, `fsync`s, and
   closes the file.
7. Child sends itself `SIGSTOP` before the callback can return.
8. Parent observes `waitpid(..., WUNTRACED)` report that exact child stopped under
   `SIGSTOP`; an exit or different stop signal fails.
9. Parent reads the stable bounded file, rejects duplicate keys, verifies canonical bytes,
   selector digest, exact hook fields, and scenario/registry digests.
10. Only then does the parent intervention return `kill`.
11. The subprocess runner sends process-group `SIGKILL`, reaps the child, drains output,
    and reports intentional termination.
12. A new oracle process opens the database read-only and classifies it.

Missing control, pre-existing control, mismatch, noncanonical JSON, changed file, missing
or wrong stop status, child exit, timeout, wrong kill signal, or retained descendants all
fail. The control record contains no database state and proves only selector coverage.
Control creation uses `O_EXCL`, `O_NOFOLLOW` where available, a verified private `0700`
parent, and a resulting regular `0600` file.

Scenario bootstrapping runs with the recorder disarmed. The recorder is armed immediately
before exactly one subject operation and rejects any second operation. Subjects call the
fixed internal persistence capability directly and start no lease-renewal/background
thread, preventing unrelated hooks from racing the selector.

## Fixed phase 2 scenarios

Each scenario has a versioned source definition, bounded setup, one action, old-state,
new-state or stable contract, convergence step, and registry coverage declaration.

| Family | Scenario | Required distinction |
|---|---|---|
| lease | `lease.acquire-new` | creates thread/namespace and fence 1 |
| lease | `lease.acquire-takeover` | expired owner is replaced and fence increases |
| lease | `lease.validate` | ownership remains and backend-clock watermark advances |
| lease | `lease.renew` | same owner/fence receives a later expiry |
| lease | `lease.release` | owner/expiry clear while fence remains monotonic |
| request | `request.enqueue-new` | one row, transition 0, FIFO counter +1 |
| request | `request.enqueue-duplicate` | identical binding remains one row/transition |
| request | `request.claim-turn` | queued turn binds one new execution and fence |
| request | `request.claim-redirect` | target execution and cancellation generation pin |
| request | `request.recover-claimed` | same execution, new fence, recovery transition |
| request | `request.recover-running` | running state/execution survive takeover |
| request | `request.recover-redirecting` | redirect target/generation survive takeover |
| request | `request.mark-running` | claimed becomes running atomically |
| request | `request.mark-redirect-running` | redirecting follows its separately valid running branch |
| request | `request.redirect-ready` | unresolved-effect query is read-only |
| checkpoint | `checkpoint.writes-new` | activation and two ordered writes appear together |
| checkpoint | `checkpoint.writes-duplicate` | exact replay adds no rows |
| checkpoint | `checkpoint.commit-start` | first running checkpoint becomes head/sequence 0 |
| checkpoint | `checkpoint.commit-advance` | pending activation consumption and head advance are atomic |
| checkpoint | `checkpoint.commit-turn` | new execution and terminal request transition share one commit |
| checkpoint | `checkpoint.commit-fork` | historical parent remains immutable; new execution becomes head |
| checkpoint | `checkpoint.commit-paused` | paused payload/head is complete or absent |
| checkpoint | `checkpoint.commit-failed` | failed payload and failed request transition agree |

The trace union must cover every phase 2 `kill_required` registry entry. Pure accessors are
source-audited and tested but are not misrepresented as kill evidence. A scenario may share
statements with another, but its old/new/stable oracle remains independent because branch
semantics differ.

## Independent raw-SQL oracle

The oracle is a standalone executable with fixed scenario ids and no arbitrary SQL input.
It:

- requires no Tamoz package or source path;
- opens SQLite read-only with `query_only`;
- runs `integrity_check` and `foreign_key_check`;
- reads only fixed ordered projections;
- recomputes every stored checkpoint, request, response/error, and pending-write digest
  with independently implemented domain separation and validates transition evidence as
  bounded canonical JSON;
- verifies contiguous checkpoint/request/transition/write indices;
- verifies namespace head/counters, lease fence/owner/expiry, request status/binding,
  checkpoint parent/execution/status, and pending-consumption relations;
- replaces generated UUIDs/timestamps with bounded logical roles;
- emits no payload, path, owner secret, or raw identifier;
- returns exactly `old`, `new`, `stable`, `partial`, or `invalid` with bounded reason
  codes.

The expected class is derived from the hook boundary:

- `before_begin`, `after_begin`, every `before_sql`/`after_sql`, and `before_commit`:
  complete old;
- `after_commit`: complete new.
- explicitly declared no-op/read-only scenarios: stable at every point.

Scenario contracts define both classes without executing the production transition to
construct expected data. A structural SQLite failure is `invalid`; a logically mixed
transaction is `partial`. Neither is accepted.

Only after old/new/stable classification may a separate Tamoz recovery process prove
convergence:

- stale lease owners remain fenced;
- duplicate request delivery retains one binding;
- claimed/running/redirecting requests recover without changing execution identity;
- durable pending writes prevent sibling re-execution;
- checkpoint history/head/request status converge to the declared terminal state.

## Profiles, sharding, and evidence

### PR profile

- records every fixed scenario trace;
- proves registry/source/trace coverage;
- performs a real kill for `before_begin`, first required statement `after_sql`,
  `before_commit`, and `after_commit` for every scenario;
- retains one evidence envelope per scenario plus a summary.

### Release profile

- executes every derived selector;
- shards by SHA-256 of selector digest modulo declared shard count;
- fixes shard count between 1 and 64;
- rejects overlap, gaps, different subject trees, registry/recorder digests, or scenario
  manifests during merge;
- enforces total selectors, child time, output bytes, artifact bytes, and wall-clock
  deadlines.

Selector order is canonical digest order, never filesystem or hash iteration order. A
release dry run can list selectors without execution. The merge result names missing
selector digests without leaking paths.

Hard ceilings:

| Resource | Ceiling |
|---|---:|
| fixed scenarios | 32 |
| hook events per scenario trace | 256 |
| derived selectors across phase 2 | 4,096 |
| shards | 64 |
| one child/oracle/recovery process | 30 seconds |
| control record | 64 KiB |
| retained stdout or stderr per process | 1 MiB |
| PR profile wall clock | 15 minutes |
| one release shard wall clock | 30 minutes |

Phase 1 artifact/reference byte limits remain authoritative. Exceeding a ceiling is an
infrastructure failure, never truncation or partial success.

Every evidence envelope binds the exact case/scenario/subject/producer/registry digests and
records:

- intentional process termination summary;
- selector control reference;
- independent oracle reference;
- old/new/stable expected and observed class;
- integrity/foreign-key gate;
- convergence result when applicable.

Artifacts remain internal and unsanitized in phase 2. Public sanitization and the six
`m3.persistence` cases land in phase 7.

## Reviewed implementation slices

1. Phase 2A: registry model, source audit, and hook metadata v1.
2. Phase 2B: trace recorder, selector derivation, and deterministic manifest tests.
3. Phase 2C: intentional subprocess intervention and evidence-schema correction.
4. Phase 2D: fsynced control protocol and malicious/mismatch treatments.
5. Phase 2E: fixed scenario setup/action drivers.
6. Phase 2F: independent raw-SQL projector and classification tests.
7. Phase 2G: PR/release matrix, sharding/merge checks, and evidence envelopes.
8. Phase 2H: regression integration and final cross-slice review.

Phase 2A is accepted in
[M3_1_PHASE2A_IMPLEMENTATION_REVIEW.md](reviews/M3_1_PHASE2A_IMPLEMENTATION_REVIEW.md).
Phase 2B is accepted in
[M3_1_PHASE2B_IMPLEMENTATION_REVIEW.md](reviews/M3_1_PHASE2B_IMPLEMENTATION_REVIEW.md).
Phase 2C is accepted in
[M3_1_PHASE2C_IMPLEMENTATION_REVIEW.md](reviews/M3_1_PHASE2C_IMPLEMENTATION_REVIEW.md).
Phase 2D is accepted in
[M3_1_PHASE2D_IMPLEMENTATION_REVIEW.md](reviews/M3_1_PHASE2D_IMPLEMENTATION_REVIEW.md).

Every slice follows the same gate: bounded implementation, adversarial self-review,
focused tests, full CI, a recorded review decision, and one slice commit. No later slice
begins while the current slice is uncommitted or has an unresolved finding. An intermediate
slice commit does not imply that Phase 2, M3.1, or any crash-safety claim is complete. If a
runtime correctness defect is found, implementation stops for a named Five Whys analysis,
regression, and explicit review correction.

## Test matrix

Deterministic/unit:

- registry deep-freeze, digest stability, duplicates, unknown templates, phase ownership;
- Ripper source audit positive/negative fixtures;
- hook schema versions, kinds, attempts, bounds, immutability;
- trace overflow, occurrence and iteration classification, selector digest/order;
- intervention state relations and timeout/intervention races;
- control `O_EXCL`, mode, fsync protocol, canonical/duplicate/mismatch/changed-file rejection;
- child stop observation, wrong stop signal, early exit, and stop/timeout races;
- shard determinism, overlap, gaps, subject mismatch, bounds;
- evidence artifact status/termination relations.

Real process:

- child blocks at the selected hook and only the parent sends `SIGKILL`;
- selector not reached fails rather than timing out as success;
- `before_commit` reopens old and `after_commit` reopens new;
- every phase 2 scenario runs PR sentinel kills;
- independent projector runs with no Tamoz feature loaded;
- recovery runs in a third process with no inherited adapter;
- output flood, invalid UTF-8, descendant retention, and intervention exception remain
  bounded by the phase 1 subprocess contract.

The pending-write convergence treatment uses a separate `synchronous=FULL` SQLite call
ledger with a uniqueness constraint on logical invocation id. It never uses an append-only
marker file. The oracle/recovery sequence proves the ledger contains one invocation before
and after recovery.

Regression:

- existing SQLite checkpoint/request/lease/crash tests;
- M0–M2 conformance;
- artifact verifier, packaging, public API, design, syntax, and full CI.

## Review gate

Implementation begins only if every answer is yes:

- Is registry completeness separated from runtime reachability?
- Are deferred operations visible without being falsely claimed?
- Does statement metadata carry the transaction attempt?
- Can a selector be replayed without raw SQL, binds, paths, payloads, or process ids?
- Does the child become unable to progress before the parent validates control?
- Does the parent independently observe the expected stopped state?
- Is intentional kill distinct from timeout and cleanup in both runtime result and schema?
- Can missing/mismatched control ever be interpreted as a passing crash?
- Does the oracle avoid every Tamoz reader/materializer and production transition?
- Are generated identities normalized by relations rather than copied into artifacts?
- Are old/new/stable/partial/invalid states explicit for every scenario?
- Are all selectors and shards finite, deterministic, and merge-verifiable?
- Does PR evidence exercise every scenario while release evidence covers every selector?
- Are phase 3–7 claims explicitly absent?
- Does every slice have a recorded deep review, full CI, and its own commit?
- Does phase 2 end with a final cross-slice review before any completion claim?

Any “no” revises this plan before runtime implementation.

## Plan review result

Accepted. [M3_1_PHASE2_PLAN_REVIEW.md](reviews/M3_1_PHASE2_PLAN_REVIEW.md) records the
adversarial findings, Five Whys analyses, corrections, acceptance conditions, and residual
limits.
