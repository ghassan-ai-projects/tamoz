# M3 implementation plan — SQLite durability foundation

Status: accepted for implementation after adversarial review on 2026-07-30.

M3 turns the deterministic M2 graph into a crash-recoverable, single-writer durable
runtime. It implements the published checkpointer, lease, request inbox, effect journal,
Store, codec, migration, backup, integrity, and deletion contracts in `tamoz-sqlite`.

M3 does not add an LLM, tools, planning policy, memory promotion, healing, MCP, scheduling,
or unbounded streaming input. It provides the truth-preserving substrate those features
must use later. It does not claim exactly-once arbitrary external effects.

## Outcome

M3 produces:

- one versioned SQLite adapter with bounded connections and short transactions;
- atomic compare-and-append checkpoints with durable successful-task writes;
- renewable leases whose fencing generations never reset;
- a FIFO, deduplicating request inbox with explicit recovery transitions;
- an effect journal that preserves every attempt receipt, including late stale-attempt
  receipts, without allowing stale graph commits;
- a compare-and-set application Store;
- graph-compatible, allowlisted checkpoint serialization with corruption digests;
- transactional schema migrations, SQLite online backup, integrity checks, tombstones,
  purge receipts, and bounded history/cursor lifetimes;
- a durable graph runner that uses those contracts without introducing a second execution
  path or weakening M2 ordering.

The redesign criterion remains active: if SQLite cannot prove atomic compare-and-append,
monotonic fenced ownership, and stop-on-unknown unsafe effects under process-kill tests, M4
does not start.

## Guarantee boundary

M3 guarantees:

- after a crash, a checkpoint transaction is observed as the complete old state or the
  complete new state;
- at most one unexpired lease generation may advance one `(thread_id, namespace)`;
- a released, expired, or deleted lease row never causes its fence generation to reset;
- duplicate external request ids create one logical request and one execution binding;
- a successful task write committed before a crash can be reused by activation identity;
- a stale effect attempt may record only its own truthful receipt;
- unsafe ambiguous effects stop as `unknown` and require an explicit resolution;
- graph compatibility and payload integrity are checked before user code;
- thread deletion blocks new work before data is removed and preserves unresolved effect
  truth until a recorded resolution or retention expiry permits purge.

M3 does not guarantee:

- exactly-once behavior from a remote system without target idempotency or reconciliation;
- termination of arbitrary stuck Ruby code;
- high write concurrency beyond SQLite's single-writer model;
- durability when the operating system or storage reports a successful synchronous write
  but loses it contrary to its contract;
- transparent recovery from database corruption;
- semantic/vector Store search;
- request delivery from a network gateway, scheduler, or stream source.

## Threat and failure model

The design treats these as ordinary expected failures:

| Failure | Required response |
|---|---|
| process exits at any SQL boundary | recover old or complete new transaction |
| two processes address one namespace | one current fence; stale writes fail |
| lease expires during a node/effect | stop new scheduling; graph write fails; exact effect receipt remains writable |
| duplicate request before/after lease or restart | same row, digest conflict on changed input, no second turn |
| remote result arrives after takeover | preserve attempt receipt; never accept stale graph state |
| unsafe call may have happened | persist `unknown`; do not retry automatically |
| `SQLITE_BUSY`/locked writer | bounded jittered retry, metric, then typed retryable failure |
| disk full or permission loss | rollback/no partial logical state; typed storage failure |
| payload/database corruption | fail before user code with corruption evidence |
| incompatible graph/record version | fail before user code; explicit migration only |
| clock jumps forward | lease may expire early; correctness holds |
| clock moves backward beyond tolerance | fail closed; do not grant or extend ownership |
| consumer stops history iteration | finalize statement and return connection |
| backup while writers are active | SQLite backup API produces one consistent destination |
| deletion races live work/receipts | tombstone blocks new work; unresolved truth blocks purge; late receipt commits |

The adversary may control serialized bytes, request ids and payloads, timing, process death,
thread timing, and duplicate delivery. The adversary may not bypass operating-system access
to the database or replace the running Tamoz code. All identifiers are bounded UTF-8 values
and all SQL values are bound parameters.

## Public runtime contracts

### Persistence protocol

`tamoz-graph` owns a structural, versioned `checkpoint.v1` protocol. A checkpointer exposes:

```ruby
latest(thread_id:, namespace: [])
find(thread_id:, namespace: [], checkpoint_id:)
history(thread_id:, namespace: [], before_sequence: nil, limit:)

open_writer(thread_id:, namespace: [], owner_id:, ttl:) do |writer|
  # no database transaction is held while this block executes user code
end
```

The yielded writer is an explicit lease-bound capability:

```ruby
writer.fence
writer.check!
writer.append_writes(task:, outcome:)
writer.append_checkpoint(expected_base_id:, mode:, attributes:,
                         consumed_task_ids: [], request_transition: nil)
```

- `MemoryCheckpointer` implements the same shape with a process-local writer and retains its
  explicit M2 non-durable guarantee.
- `Tamoz::SQLite::Adapter` implements it with a renewable lease guard.
- The writer is passed explicitly through `Compiled`, `Executor`, and subgraph execution.
  It is never stored in a thread/fiber local or mutable process global.
- `open_writer` owns lease acquisition, renewal supervision, loss notification, best-effort
  release, and cleanup. The adapter never holds a SQL transaction while a node runs.
- `writer.check!` runs before task scheduling and every write. A failed renewal cancels
  cooperative work and causes `LeaseLostError`.
- Lease, checkpoint, codec, corruption, and storage failures raised inside a worker-side
  `append_writes` are fatal runtime results. The pool returns them through a dedicated fatal
  path; the executor does not wrap them in `NodeError`, convert them into tool values, or
  append a misleading failed-node checkpoint.
- Direct read methods need no lease and close their statements/connections on normal return,
  exception, or early enumerator close.

The compiler checks the declared protocol version and required methods. Optional request,
effect, and Store capabilities have independent protocol versions; capability absence is
reported and never treated as conformance.

### Checkpoint codec

`tamoz-graph` owns `CheckpointCodec` because only the compiled graph can safely interpret
channel, node, route, and managed-value identities. The SQLite adapter owns bytes, digests,
transactions, and indexes but does not invent graph semantics.

The codec:

- emits a canonical `tamoz.graph.checkpoint` JSON envelope at format version 1;
- uses `StateCodec` for every user value and preserves its byte/depth/item/string limits;
- encodes framework records through fixed array shapes, never `Marshal` or JSON additions;
- checks the stored graph name, version, digest version, and definition digest before
  resolving node/channel strings against the compiled definition's existing identifiers;
- never calls `to_sym` on persisted input;
- rejects unknown/duplicate fields, tags, record versions, invalid UTF-8, non-canonical
  shapes, excessive nesting/size, and secret wrappers before user code;
- includes a domain-separated SHA-256 digest stored beside every payload and verifies it
  before decode;
- has pure, fixture-backed `old_hash -> new_hash` migrations. A migration creates a new
  checkpoint; it never rewrites historical bytes in place.

Database schema version, checkpoint format version, StateCodec version, definition digest
version, and application graph version remain separate values.

### Durable task writes and checkpoint commit

One successful logical activation is persisted as:

- one `tamoz_pending_activations` record containing execution, activation, attempt, base,
  node/path, and a canonical whole-outcome digest;
- ordered `tamoz_pending_writes` children for channel values and routing output.

The complete activation is inserted in one transaction and is idempotent by
`(thread, namespace, execution_id, task_id)`. Repeating identical bytes returns
`already_present`; a different attempt/base/outcome for the same activation conflicts.

Workers append their normalized successful outcome before returning it to the coordinator.
Therefore a crash after a successful sibling result but before pause/failure/barrier commit
can recover that sibling without rerunning it. External effects still require the effect
journal; a task write alone is not proof of a remote outcome.

Checkpoint commit runs in one `BEGIN IMMEDIATE` transaction:

1. verify thread is not tombstoned;
2. verify lease owner, fence, expiry, and clock guard;
3. verify the expected base and commit mode;
4. verify execution identity and every consumed activation;
5. allocate the next integer sequence from the namespace head;
6. insert the complete checkpoint and payload digest;
7. mark the selected pending activations consumed by that checkpoint;
8. apply an optional request transition;
9. move the namespace active tip;
10. commit synchronously.

`:start`, `:advance`, `:turn`, and `:fork` retain their published meanings. A fork may use a
historical base while holding the current namespace lease, gets a new execution id, becomes
the active tip, and consumes no source execution writes or effects.

Pause and failure checkpoints do not consume successful siblings. A successful barrier
consumes its complete activation set. Writes committed just before a crash but not yet
associated remain recoverable from the active execution; they are not guessed into another
execution.

### Lease and clock contract

The namespace head, not a disposable lease row, owns `lease_fence`. Release clears current
ownership and expiry but preserves the generation. Every acquisition after an absent,
released, or expired owner increments it in the same transaction.

Lease timestamps are integer milliseconds from a SQLite expression evaluated inside the
write transaction. Callers never provide expiry timestamps. A local monotonic clock only
schedules renewal attempts; it is not ownership evidence.

The namespace row also stores the greatest accepted backend time. If backend time moves
backward beyond a small configured tolerance, acquisition, renewal, and durable writes fail
closed with an observable clock error until time catches up or an explicit offline
operator-recovery procedure records a reset. A forward jump may discard work by expiring a
lease early, but it cannot authorize two fences.

Lease TTL, renewal interval, busy timeout, checkout timeout, and retry budget are bounded.
Renewal occurs before half TTL. Same-owner reentrant acquisition is rejected; every writer
session uses a unique owner id.

### Durable request runner

Low-level graph execution remains useful with `MemoryCheckpointer`. A durable adapter adds
`Tamoz::Graph::DurableRunner`, the only public path that turns an external delivery into
durable graph work:

```ruby
runner.submit(thread:, request_id:, operation: :turn, payload:, delivery: :queue)
runner.run_next(thread:, namespace: [], owner_id: SecureRandom.uuid)
runner.deliver(...) # submit, then opportunistically process or return durable status
```

Operations are `turn`, `resume`, `retry`, `continue`, `fork`, and `redirect`. The request
payload is codec-bounded and its digest includes the operation and delivery mode.

- enqueue occurs before lease acquisition;
- request ids are opaque, valid UTF-8, at most 128 bytes, and byte-compared;
- enqueue sequence is allocated atomically per namespace;
- same id/same digest returns the existing request; same id/different digest conflicts;
- claim skips no earlier nonterminal request and binds its execution exactly once;
- turn, fork, and redirect allocate a new execution; resume/retry/continue bind the
  checkpoint's existing execution;
- claimed/running/redirecting recovery is an explicit compare-and-set transition;
- redirect pins target execution and cancellation generation once, and cannot run until
  in-flight effects are terminal or explicitly reconciled;
- the terminal checkpoint and completed/failed request transition share one adapter
  transaction;
- duplicate callers may inspect/join status or return a stored terminal response, but never
  create a second graph turn.

`Compiled#invoke` is not silently upgraded into a queue API with a polymorphic return type.
For a durable adapter it is an internal runner operation; external callers use
`DurableRunner`. This keeps `RunResult` and `RequestRecord` distinct and prevents a surface
from accidentally bypassing inbox deduplication.

Public `invoke`, `resume`, `retry_failed`, `continue`, and mutating `update_state` reject a
durable adapter. `DurableRunner` reaches private writer-bound execution methods; public
state/history reads remain available. A durable caller cannot opt out of the inbox with
`new_execution: true`.

### Effect journal

An effect has one immutable head and append-only attempts:

```text
effect_key = digest(thread_id, namespace, execution_id,
                    logical_activation_id, call_index, operation)
```

`attempt_id` and base checkpoint are excluded. The immutable head binds operation, safety
class, and request digest. `tamoz_effect_attempts` stores every attempt number, random token,
authorizing fence, deadline, status, and terminal receipt.

The public sequence is explicit:

```ruby
decision = effects.prepare(..., fence:)
effects.start(key:, attempt_token:, fence:)
effects.complete(key:, attempt_token:, status:, result: nil,
                 external_id: nil, error: nil)
```

- `prepare` validates the current graph fence and returns `execute`, `return`, `wait`,
  `reconcile`, `unknown`, or `failed`;
- `start` is a compare-and-set from prepared to running immediately before target I/O and
  revalidates the still-current graph fence and attempt deadline. A token by itself never
  authorizes starting I/O after lease loss;
- `complete` is authorized by the exact attempt token, not the current graph lease;
- completion remains available after graph lease loss and thread tombstoning;
- a late old token updates only its own append-only attempt receipt;
- an old receipt never overwrites a newer head; conflicting successful attempts mark the
  head as requiring reconciliation;
- succeeded heads are immutable except for audit metadata;
- expired read-only/idempotent attempts may be retried only through an explicit journal
  decision; idempotent retries reuse the effect key at the target;
- transactional effects read their local committed result;
- reconcilable effects return `reconcile`;
- expired/ambiguous unsafe effects become `unknown` and cannot issue another token;
- human resolution or abandonment is a separately authorized, append-only transition.

The separate attempt table is required. A single mutable effect row would lose a stale
attempt's truthful late receipt as soon as a newer token replaced it.

### Store

M3 includes the architecture's minimal exact Store because `tamoz-sqlite` is the v0.1 owner
and later memory depends on compare-and-set history:

```ruby
put(namespace, key, value, if_version: nil, sensitive: false)
get(namespace, key)
delete(namespace, key, if_version: nil)
each(namespace, prefix: nil, limit:)
searchable? # false in M3
```

Store values are append-versioned with a compare-and-set head. Namespace and key are bounded
UTF-8. Iteration is byte-ordered and cursor-safe. M3 does not expose semantic `search`; a
non-searchable Store raises a capability error rather than pretending prefix lookup is
semantic retrieval. `sensitive: true` requires a named authenticated-encryption codec whose
key provider is outside SQLite; without one the write raises `SensitiveValueError` instead
of storing plaintext. Tenant prefix enforcement remains a later session-boundary concern
and must exist before agent memory is enabled.

## SQLite layout

Migration 1 creates only M3 foundation tables:

| Table | Purpose |
|---|---|
| `tamoz_schema_migrations` | ordered version and immutable migration checksum |
| `tamoz_threads` | thread existence and tombstone state |
| `tamoz_namespaces` | active tip, sequence counters, current owner, monotonic fence, clock guard |
| `tamoz_checkpoints` | immutable checkpoint envelope, identity columns, digest |
| `tamoz_pending_activations` | one idempotent successful logical task result |
| `tamoz_pending_writes` | ordered channel/route children of an activation |
| `tamoz_requests` | durable queue head and terminal result |
| `tamoz_request_transitions` | append-only claim/recovery/redirect/terminal audit |
| `tamoz_effects` | immutable effect identity and current decision head |
| `tamoz_effect_attempts` | append-only token-owned attempts and receipts |
| `tamoz_effect_transitions` | reconciliation/resolution audit |
| `tamoz_store_heads` | current Store version |
| `tamoz_store_versions` | append-only Store values/tombstones |
| `tamoz_thread_tombstones` | compare-protected deletion intent and live report |
| `tamoz_deletion_receipts` | retained final purge evidence |

Schedule, occurrence, MCP, memory-specific vector/index, and stream tables are not created in
M3. Their optional protocol migrations load only when those packages are implemented.

Structural rules:

- every child table has explicit foreign keys and tested delete behavior;
- namespaces are canonical JSON arrays, not delimiter-joined strings;
- active checkpoint and request counters live in the namespace head; `MAX(sequence)+1` is
  never used for allocation;
- timestamps and lease deadlines are integer milliseconds; ordering never uses them;
- checkpoint/effect/request ids are opaque random identities; correctness never uses their
  lexical order;
- status and safety fields have `CHECK` constraints;
- payload lengths and digests are verified in Ruby before decode;
- unresolved effect attempts are not cascade-deleted by a thread purge;
- final deletion receipts are outside the purged thread's foreign-key tree.

## Connection, transaction, and file policy

The adapter uses `sqlite3 ~> 2.9`; the reviewed development lock is 2.9.5, whose published
Ruby requirement is `>= 3.2`. Tamoz still supports Ruby 3.3, 3.4, and 4.0. The dependency is
direct and declared by `tamoz-sqlite`.

One adapter owns a bounded connection pool:

- each operation checks out one connection; statements/result sets never cross threads;
- checkout has a bounded timeout and `ensure` return;
- an inherited adapter is detected by PID and fails closed. Callers close before fork and
  construct a new adapter in the child; the adapter never tries to recover an inherited
  possibly locked Ruby mutex or writable SQLite connection;
- every connection enables foreign keys, WAL, `synchronous=FULL`, a bounded busy handler,
  and a known row/result mode;
- transactions use explicit begin/commit/rollback and never `execute_batch` with
  caller-controlled content;
- write contention retries only recognized busy/locked errors, with bounded monotonic
  backoff and instrumentation. Busy handler time, connection checkout, and outer retries
  share one total deadline rather than multiplying independent timeout budgets;
- transaction retries rerun storage-only closures. Random identities are allocated before
  the retry loop, and no user callback, event emission, clock callback, or external I/O
  occurs inside a retried transaction;
- adapter `close` is idempotent and rejects new checkout;
- no finalizer is relied upon for correctness.

WAL auto-checkpoint size is configured and observed. Backup, integrity, close, and the soak
suite explicitly checkpoint WAL where safe; an unbounded WAL is a release failure.

New database and backup files are created as regular files with mode `0600`; symlink
destinations are rejected. Existing files with group/other permissions fail closed unless
the caller explicitly requests a recorded permission repair. WAL/SHM permissions are
verified. Database URIs and arbitrary VFS parameters are not accepted in v1.

The migration runner:

- validates SQLite application id and every applied migration checksum;
- uses an exclusive migration transaction and records `user_version` only with the DDL;
- refuses unknown newer schema versions;
- rolls back the complete migration on any statement/hook failure;
- supports only forward migrations in production;
- proves upgrades from every retained fixture.

Backup uses `SQLite3::Backup`, steps with bounded busy handling, finalizes in `ensure`, runs
integrity and application/schema checks on the destination, applies mode `0600`, and
atomically publishes a new destination. It does not raw-copy an open WAL database and does
not overwrite an existing destination implicitly.

## Deletion and retention

Retention and deletion remain different operations.

- `prune` may remove eligible historical checkpoints but preserves active tips, parents
  needed by retained history, unconsumed writes, request/effect linkage, and a report.
- `tombstone_thread` validates expected tips for every namespace in one transaction.
- A live lease blocks tombstoning unless the caller presents that exact current fence.
- Prepared, running, or unknown effects block tombstoning unless a
  `DeletionAuthorization` records an explicit per-effect reconciliation or abandonment.
- Tombstoning immediately blocks enqueue, lease acquisition, turn, fork, effect prepare,
  and durable graph writes other than exact late effect receipts. Generic cross-thread
  Store keys are not assumed to belong to a graph thread; application-memory deletion gets
  its own provenance-aware contract in M5b.
- Purge requires the tombstone id, no unresolved attempt, and either terminal receipts or
  expiration of the configured receipt/reconciliation window.
- Purge writes a durable deletion receipt containing counts, retained/abandoned identities,
  policy, actor/reason digest, and artifact digests before removing the thread tree.
- The tombstone/deletion receipt is idempotently queryable after purge.

User-facing confirmation and authorization policy are application responsibilities, but
the adapter requires a typed immutable authorization record rather than a boolean flag.

## Durable graph integration

There remains one planner, executor, barrier, reducer, and stream path.

Required M2 changes:

1. replace `checkpointer.synchronize` with explicit `open_writer`;
2. pass the writer through `Compiled`, `Executor`, and subgraph runtime;
3. append a successful task outcome before returning it to the coordinator;
4. load reusable durable outcomes by stable activation identity;
5. include consumed activation ids and optional request transition in checkpoint append;
6. attach the adapter's Store and effect journal to Context only through adapter-minted
   scoped capabilities; a durable runner rejects arbitrary replacement journals because
   they would bypass its effect and receipt boundary;
7. call writer/lease checks before scheduling and before every barrier append;
8. let `DurableRunner` own request transitions and execution binding.

Memory execution must retain its exact public behavior and committed checkpoint fixtures.
Inline/threaded scheduling still sorts by task path. Storage completion order, SQL row order,
random ids, lease timing, and request sequence never enter reducer or route order.

Subgraphs inherit the same adapter and deterministic namespace. Each namespace has its own
lease generation, while thread tombstones span all namespaces. No child constructs an
adapter or connection pool.

## Implementation slices

Implementation proceeds only after this plan passes review:

1. **Protocol and codec**
   - versioned graph persistence values/errors;
   - `CheckpointCodec` round trips/rejections/migrations;
   - writer-session refactor with MemoryCheckpointer equivalence.
2. **SQLite kernel**
   - dependency, secure file open, bounded pool, pragmas, transaction wrapper;
   - migration 1, schema checksum, integrity command, fault hooks.
3. **Leases and checkpoints**
   - namespace head, monotonic fences, renewal guard, backend clock guard;
   - pending activation writes, atomic checkpoint commit, history and prune.
4. **Requests and durable runner**
   - enqueue/claim/recovery/redirect state machine;
   - execution binding and atomic terminal checkpoint transition.
5. **Effects**
   - immutable effect head, append-only attempts, decisions, late receipts,
     reconciliation/unknown resolution.
6. **Store, backup, and deletion**
   - compare-and-set Store, cursor safety, online backup;
   - tombstone, late receipt sink, purge receipt.
7. **Adversarial evidence**
   - conformance, process kills, multi-process races, faults, leaks, performance,
     package/dependency isolation, public M3 eval cases.

Each slice must keep the complete M0–M2 gate green. M3 is committed only once, after its
deep review and clean-revision evidence; no later phase begins before that commit.

## Test and evaluation matrix

### Deterministic and model tests

- MemoryCheckpointer histories remain byte-identical to the committed M2 fixtures.
- Inline and threaded SQLite runs produce identical logical checkpoint projections.
- A reference state machine generates checkpoint modes, lease ownership, request
  transitions, effect attempts, and deletion transitions, then compares adapter state.
- Property tests randomize completion order, busy errors, retry points, duplicate delivery,
  lease takeover, and cursor early close.
- Golden fixtures pin checkpoint, activation, attempt, request, and effect identity recipes.

### Process-kill checkpoint matrix

An explicit internal fault hook names every storage boundary. A subprocess is killed before
and after every SQL statement in:

- database creation and migration;
- request enqueue, claim, redirect, recovery, and terminal transition;
- lease acquire, renew, release, and takeover;
- task activation/write append;
- start/advance/pause/fail/turn/fork checkpoint commit;
- pending-write consumption;
- effect prepare, start, complete, reconcile, and resolve;
- Store compare-and-set;
- prune, tombstone, purge, and backup publication.

Recovery must observe the old complete state or new complete state. The harness records
which hook fired and validates the reopened database independently.

### Lease and request races

- race at least two processes for one namespace; exactly one fence is live;
- release and reacquire repeatedly; fences strictly increase and never reset;
- expire A, acquire B, then deliver A's delayed task write/checkpoint; both fail with
  `LeaseLostError`;
- move backend time forward/backward and prove fail-closed clock behavior;
- enqueue the same request concurrently before any lease and after restart; one row and one
  execution binding exist;
- enqueue many requests from distinct processes; FIFO by backend sequence holds;
- kill every claimed/running/redirecting transition and prove explicit recovery.

### Effect matrix

For every safety class, kill:

```text
before prepare
after prepare / before start
after start / before target call
during target call
after target success / before receipt
after receipt / before task write
after task write / before checkpoint
```

Assertions:

- read-only and idempotent cases converge only through explicit allowed retry;
- transactional cases recover local proof;
- reconcilable cases return `reconcile`, then terminal or `unknown`;
- unsafe ambiguity records `unknown` and issues zero automatic retries;
- old and current attempt receipts are both retained;
- an old token cannot overwrite a newer head or commit graph state;
- tombstoning blocks new attempts but accepts an exact late receipt.

### Storage, security, and resource faults

- real `SQLITE_BUSY`/locked writer and bounded exhaustion;
- `SQLITE_FULL` through a constrained database;
- permission loss and secure-mode failures;
- malformed/truncated/duplicate/deep/oversized checkpoint and Store payloads;
- row digest mismatch, corrupt database page, and unsupported schema/record versions;
- failed migration at every statement and checksum mismatch;
- raw copy of a live WAL database is rejected as evidence; backup API restore succeeds;
- path/symlink/URI attacks and request/namespace identifier boundary fuzzing;
- `Tamoz::Secret` through checkpoint, request, effect receipt, Store, logs, errors, and
  `inspect`;
- early-break history/Store enumeration returns statements/connections;
- ten thousand short sessions track RSS, threads, file descriptors, connections, and WAL
  size; every retained resource returns to a named baseline.

### Performance and packaging

Record CPU/OS/storage, Ruby/SQLite versions, state bytes, warmup, samples, p50/p95/p99,
allocations, retained memory, and SQLite-direct baseline.

- small-state synchronous commit target: `< 10 ms p95` on named local SSD hardware;
- resume from 500 checkpoints target: `< 50 ms p95`;
- a regression over 15% against the same-runner baseline requires explanation;
- performance is reported, not hidden by loosening correctness pragmas.

Run Ruby 3.3, 3.4, and 4.0 CI, installed-gem smoke, package-content review, clean-process
dependency checks, public `m3.persistence` evaluation cases, and OS-denied network evidence.

## Review gate

Implementation may begin only if every answer is yes:

- Does every write that changes graph/request/effect ownership validate a current explicit
  fence, while exact late effect completion intentionally uses its attempt token instead?
- Can any lease lifecycle reset or reuse a fencing generation?
- Can a SQL/process failure expose a partial logical transition?
- Can a successful sibling outcome survive a crash without being mistaken for another
  activation, attempt, base, or execution?
- Does graph compatibility and payload integrity fail before framework identifier revival
  or user code?
- Does duplicate request delivery bind one operation/digest/execution and preserve FIFO?
- Can every claimed/running/redirecting request state be recovered explicitly?
- Can every effect attempt retain its own receipt after timeout, takeover, tombstone, and a
  newer attempt?
- Is unsafe ambiguity a durable stop state with no automatic retry path?
- Can deletion block new work without destroying the receipt sink or unresolved truth?
- Are database transactions absent from node, model, tool, callback, and network execution?
- Are pool, busy, retry, TTL, history, payload, cursor, backup, and deletion windows bounded?
- Does the integration preserve the single M2 planner/executor/barrier and memory fixtures?
- Can every conformance claim be demonstrated under process kill, not only mocked exception?
- Are unsupported Store search, scheduling, MCP, stream, model, and exactly-once claims
  explicitly absent?

Any “no” revises this plan before implementation.

## Plan review result

Accepted. [M3_PLAN_REVIEW.md](reviews/M3_PLAN_REVIEW.md) records the review method, resolved
findings, Five Whys analyses, residual risks, and implementation evidence gate.

The accepted plan corrected four critical design errors before code: fencing generations
now survive release, effect start revalidates the graph fence, durable worker failures have
a fatal path, and effect attempts are append-only so late receipts cannot be erased by a
newer token. It also closed durable-invocation bypass, untrusted identifier revival,
worker-result crash loss, clock rollback, context-journal replacement, timeout
multiplication, post-fork pool recovery, Store deletion ownership, WAL growth, and
sensitive-plaintext ambiguities.
