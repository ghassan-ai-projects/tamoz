# Persistence

Four contracts are deliberately separate:

| Contract | Scope | Purpose |
|---|---|---|
| Checkpointer | one graph thread | committed state, pending task writes, replay, fork |
| Effect journal | one external operation | decide return, retry, reconcile, or stop |
| Request inbox | one surface input | deduplicate and order CLI/gateway/cron delivery |
| Store | across threads | explicit application memory and user data |

A checkpointer makes graph state durable. It cannot make an unrelated API, filesystem, or
shell effect part of the same transaction. The effect journal exists to represent that
boundary honestly.

## 1. Checkpoint records

```ruby
# Illustrative
Tamoz::Checkpoint = Data.define(
  :format_version,
  :id,                 # opaque identity, never ordering
  :sequence,           # strict order within thread_id + ns
  :thread_id,
  :ns,
  :execution_id,       # stable across resume; new for fork/new external turn
  :parent_id,
  :graph_name,
  :graph_version,
  :digest_version,
  :definition_digest,
  :fence,
  :created_at,
  :channel_values,
  :channel_versions,
  :versions_seen,
  :updated_channels,
  :tasks,               # pending failures/interrupts with stable task + call ids
  :metadata
)

Tamoz::PendingWrite = Data.define(
  :execution_id, :task_id, :attempt_id, :base_checkpoint_id, :index, :channel, :value
)

Tamoz::CheckpointView = Data.define(
  :checkpoint, :pending_writes, :interrupts
)
```

Structural rules:

- `sequence` is allocated by the backend under the thread namespace. It, not a UUID or wall
  clock, defines latest and history order.
- ids are globally unique opaque values. UUIDv7 is acceptable for identity and locality,
  but correctness never depends on its lexical order.
- `(thread_id, ns)` is the durable address. A unique constraint on
  `(thread_id, ns, sequence)` prevents competing histories.
- pending writes attach to one execution and stable logical task activation. They are
  idempotent on `(execution_id, task_id, index)` so a successful sibling result survives an
  interrupt checkpoint and is not invoked again. `attempt_id` and `base_checkpoint_id`
  preserve the invocation provenance and must match the attempt that produced the write.
- graph identity and the committing fence are data, not log decoration.

## 2. Checkpointer contract

The contract favors complete state transitions over a method-count target:

```ruby
# Illustrative
load(thread_id:, ns: "", checkpoint_id: nil)
# => CheckpointView | nil

append_writes(execution_id:, task_id:, attempt_id:, base_checkpoint_id:, writes:, fence:)
# => :inserted | :already_present

commit(execution_id:, base_checkpoint_id:, checkpoint:, consumed_task_ids:, fence:,
       mode: :advance) # :advance | :turn | :fork
# => committed Checkpoint; atomic compare-and-append

each(thread_id:, ns: "", before_sequence: nil, limit: nil, filter: {})
# => lazy Enumerator, newest first

lease(thread_id:, ns: "", owner_id:, ttl:)
# => Lease with #fence, #renew!, #release!

tombstone_thread(thread_id:, expected_tips:, effect_policy: :require_terminal)
# => tombstone + deletion report

purge_thread(thread_id:, tombstone_id:)
# => final deletion report
```

Required semantics:

- `append_writes` is one atomic, idempotent operation.
- `commit(mode: :advance)` executes in one storage transaction. It verifies the base
  checkpoint is still the active tip, verifies the same execution id and lease fence,
  assigns the next sequence, inserts the full checkpoint, and marks that execution's
  pending writes consumed. On failure it changes nothing.
- `mode: :turn` requires the active tip but starts the request inbox's newly allocated
  execution id. It is used for the first input checkpoint of a new external turn.
- explicit `mode: :fork` may use a historical parent while holding the current thread lease.
  It creates a new execution id and makes the appended checkpoint the active tip. It never
  consumes pending writes or effect receipts from the source execution implicitly.
- an adapter without atomic compare-and-append does not conform.
- `load` returns only pending writes for the selected checkpoint's execution id and live
  activation set so scheduling can be derived from one consistent read.
- `each` is lazy and closes its cursor on completion, exception, or early break.
- deletion is two phase, compare-protected, and returns counts. `tombstone_thread` makes the
  thread unavailable for new requests, turns, forks, and effects; user-facing deletion
  requires explicit confirmation. Retention uses `prune`, never deletion.
- tombstoning fails while a live lease exists unless the caller presents that lease's fence.
  It also fails while an effect is `prepared`, `running`, or `unknown`, unless the caller
  supplies a separately authorized policy that records reconciliation or explicit
  abandonment for every such effect.
- late completion remains writable to the effect receipt sink after tombstoning. `purge_thread`
  is permitted only after all attempts are terminal or past their retained reconciliation
  window and a deletion receipt proves which records were removed, retained, or abandoned.

There is no `next_version` adapter method. Channel versions are graph semantics and use
integers allocated by the barrier. Backends persist them; they do not invent them.

## 3. Leases and fencing

A process-local mutex is insufficient once a CLI, cron runner, gateway, or second process
can address the same thread. The backend grants a lease:

```ruby
Tamoz::Lease = Data.define(
  :thread_id, :ns, :owner_id, :fence, :expires_at
)
```

- acquisition is an atomic insert/update only when no unexpired lease exists;
- expiry comparisons use backend time, never a process-supplied timestamp;
- every successful ownership change increments `fence`;
- the runner renews before half the TTL and stops scheduling new work if renewal fails;
- every `append_writes` and `commit` includes the fence;
- release is best-effort; expiry provides crash recovery;
- a stale owner can finish a remote call but cannot commit after a newer fence exists.

SQLite implements acquisition and commit with short `BEGIN IMMEDIATE` transactions. It
never holds a database transaction while executing a node. WAL permits concurrent readers,
but SQLite still permits only one writer at a time, so busy retries are bounded and
instrumented.

## 4. Effect journal and the impossibility boundary

Each effect gets a deterministic key:

```text
effect_key = digest(thread_id, ns, execution_id, task_id, call_index, operation_name)
```

Here `task_id` is the stable logical activation id. Attempt number and resume checkpoint are
excluded so retry, interruption, and lease takeover consult the same effect record.

The journal stores:

```ruby
Tamoz::EffectRecord = Data.define(
  :format_version,
  :key,
  :thread_id,
  :ns,
  :execution_id,
  :operation,
  :safety,          # :read_only | :idempotent | :transactional | :reconcilable | :unsafe
  :status,          # :prepared | :running | :succeeded | :failed | :unknown
  :attempts,
  :request_digest,
  :result,
  :external_id,
  :error,
  :fence,
  :attempt_token,
  :attempt_deadline,
  :updated_at
)
```

Contract:

```ruby
fetch(key)
prepare(key:, thread_id:, ns:, execution_id:, operation:, safety:,
        request_digest:, fence:)
# => EffectDecision with action + attempt_token when execution is granted

complete(key:, attempt_token:, status:, result: nil, external_id: nil, error: nil)
```

The graph fence authorizes starting an attempt. The returned random attempt token authorizes
recording its outcome. Completion does **not** require the graph lease still to be current:
an operation may finish after lease expiry, and losing that truthful receipt would cause the
new owner to guess. A stale owner may complete only its exact effect attempt; it still
cannot append graph writes or commit a checkpoint.

An unexpired `:running` attempt is never executed concurrently by a new owner. After its
deadline, the next owner applies the safety-specific reconcile/retry policy.

Effect transitions are compare-and-set:

- reusing a key with a different operation or request digest is a conflict;
- `:running` or `:unknown` may become terminal only for the same attempt token;
- a newer attempt token prevents an older worker from overwriting its outcome;
- `:succeeded` is immutable and always returns the recorded receipt;
- retry increments `attempts` and issues a new attempt token only after safety policy allows
  it.

Replay policy:

| Safety | After ambiguous crash |
|---|---|
| `:read_only` | retry |
| `:idempotent` | retry with the same key; target must enforce the key |
| `:transactional` | read the local committed result |
| `:reconcilable` | query target by external id/key, then complete or mark unknown |
| `:unsafe` | mark `:unknown`; pause for human resolution; never retry automatically |

The journal narrows ambiguity but cannot remove the two-generals gap. If the process dies
after a remote non-idempotent operation succeeds and before the receipt commits, only the
remote target can resolve what happened. The framework treats uncertainty as state rather
than guessing.

Model calls also use effect identities. A provider may still charge twice if it offers no
idempotency or result lookup and the process dies after response delivery but before the
receipt commit. Tamoz exposes this as an operational metric; it does not claim otherwise.

## 5. Durable request inbox

Every external input carries a caller-generated stable request id:

```ruby
fetch_request(thread_id:, ns:, request_id:)
enqueue_request(thread_id:, ns:, request_id:, input_digest:, payload:, delivery:)
claim_next_request(thread_id:, ns:, fence:)
mark_redirecting(thread_id:, ns:, request_id:, target_execution_id:, fence:)
complete_request(thread_id:, ns:, request_id:, checkpoint_id:, response:, fence:)
fail_request(thread_id:, ns:, request_id:, error:, retryable:, fence:)
```

Request ids are opaque UTF-8 strings capped at 128 bytes and compared byte-for-byte after
UTF-8 validation; Tamoz never interprets them as paths or SQL fragments.

`enqueue_request` is the surface-facing operation and does not require the graph lease. It
atomically allocates a backend sequence within `(thread_id, ns)` and returns the existing
record on duplicate. A duplicate may observe/join the active run, return the completed
response, or report the prior terminal failure; it never appends another user event. Reusing
an id with a different input digest is a conflict.

The state machine is explicit:

```text
queued ──claim-next──▶ claimed ──turn-start──▶ running ──▶ completed | failed
   │                       │
   └─redirect delivery─────┴──▶ redirecting ──reconcile active effects──▶ running
```

Queue delivery is FIFO by backend sequence. `claim_next_request` runs under the thread lease,
skips no earlier nonterminal queue item, and atomically allocates the new `execution_id`.
Redirect delivery records its target execution and cancellation generation exactly once;
the owner reconciles any in-flight effect before starting the redirect as a new execution.
Crash recovery uses explicit transitions from `claimed`, `redirecting`, or `running`; it
never silently creates a second execution. Cancellation and terminal failures are durable.

Resume preserves the interrupted execution id and stable activation ids. A new queued turn,
redirect, or explicit fork allocates a new execution id. This prevents task activations,
pending writes, and effect receipts from leaking across intentional re-execution.

Request completion and the terminal checkpoint are committed in one adapter transaction
when they share a backend. A request abandoned after lease loss remains claimable only
through an explicit recovery transition.

Durable v0.1 compilation requires the request inbox and checkpointer to come from the same
adapter so terminal request completion can be atomic with the checkpoint.

### 5.1 StreamStore

`tamoz-stream` uses a separate durability algebra because graph checkpoints are episodic
state, not stream recovery:

```ruby
# Illustrative
admit_event(channel_id:, revision:, envelope:, payload_hash:)
# => :inserted | :duplicate | :quarantined | :rejected

load_partition(partition_id:)
# => state + watermark + timers + checkpoint

commit_partition(partition_id:, expected_checkpoint:, inbox:, operator_state:,
                 watermark:, timers:, situation_versions:, trigger_evaluations:,
                 admissions:, outbox:)
# => atomic next checkpoint

append_outcome(command_id:, receipt:, observation:)
# => idempotent outcome event
```

One partition commit atomically advances inbox/dedup, deterministic operator/timer state,
immutable Situation versions, trigger/admission history, outbox, and checkpoint. It never
contains a model, broker, approval, or effector call. Stable event ids and canonical payload
hashes make redelivery idempotent; a conflicting hash quarantines the event.

The SQLite adapter adds channel revisions, source sessions, event log/inbox, partition
checkpoints, bounded operator state, watermarks, timers, gap records, Situation
specs/versions/heads, trigger evaluations, cognition admissions, Decisions/Intents,
Commands/outbox/Outcomes, and replay artifacts. Foreign keys preserve lineage from a
physical Command back to its policy decision, accepted plan, immutable Situation snapshot,
and admitted observations.

## 6. Serialization and sensitive data

Durable state is a versioned wire format, not arbitrary Ruby object revival.

- JSON is the default envelope.
- permitted scalar/container shapes are explicit.
- framework types use registered, versioned codecs with allowlisted tags.
- unknown tags, duplicate keys, invalid UTF-8, excessive nesting, or unsupported versions
  fail before any user code runs.
- symbols serialize as strings and are converted only for schema-declared state keys; no
  attacker-controlled symbol interning.
- `Marshal` is not shipped, even for development. A dev-only escape hatch tends to become a
  production incident.
- migrations are pure `old_hash -> new_hash` functions. Fixtures prove every supported
  version upgrades or fails with an actionable error.

Serialization must be lossless. It never removes keys matching a secret-looking regex.
That approach both misses secrets in innocently named fields and corrupts legitimate state.

Instead:

- `Tamoz::Secret` and credential handles are non-serializable by default;
- credentials live in an injected credential provider and state stores only opaque
  references;
- applications may mark state fields `sensitive: true` and select an authenticated
  encryption codec whose key comes from outside the checkpoint database;
- streams, instrumentation, exceptions, and `inspect` apply the same classification policy;
- SQLite files are created mode `0600`; backup policy must preserve permissions and, when
  configured, encryption.

## 7. SQLite schema

Illustrative; migrations own the final DDL.

```sql
CREATE TABLE tamoz_checkpoints (
  id                 TEXT PRIMARY KEY,
  thread_id          TEXT NOT NULL,
  ns                 TEXT NOT NULL DEFAULT '',
  execution_id       TEXT NOT NULL,
  sequence           INTEGER NOT NULL,
  parent_id          TEXT,
  format_version     INTEGER NOT NULL,
  graph_name         TEXT NOT NULL,
  graph_version      TEXT NOT NULL,
  digest_version     INTEGER NOT NULL,
  definition_digest  TEXT NOT NULL,
  fence              INTEGER NOT NULL,
  created_at          TEXT NOT NULL,
  source              TEXT NOT NULL,
  payload             BLOB NOT NULL,
  UNIQUE (thread_id, ns, sequence)
);

CREATE INDEX idx_tamoz_checkpoint_history
  ON tamoz_checkpoints (thread_id, ns, sequence DESC);

CREATE TABLE tamoz_pending_writes (
  execution_id       TEXT NOT NULL,
  task_id            TEXT NOT NULL,
  attempt_id         TEXT NOT NULL,
  base_checkpoint_id TEXT NOT NULL,
  write_index        INTEGER NOT NULL,
  channel            TEXT NOT NULL,
  value              BLOB NOT NULL,
  consumed_by        TEXT,
  PRIMARY KEY (execution_id, task_id, write_index)
);

CREATE TABLE tamoz_leases (
  thread_id   TEXT NOT NULL,
  ns          TEXT NOT NULL DEFAULT '',
  owner_id    TEXT NOT NULL,
  fence       INTEGER NOT NULL,
  expires_at  TEXT NOT NULL,
  PRIMARY KEY (thread_id, ns)
);

CREATE TABLE tamoz_effects (
  effect_key       TEXT PRIMARY KEY,
  thread_id        TEXT NOT NULL,
  ns               TEXT NOT NULL DEFAULT '',
  execution_id     TEXT NOT NULL,
  operation        TEXT NOT NULL,
  safety           TEXT NOT NULL,
  status           TEXT NOT NULL,
  attempts         INTEGER NOT NULL,
  request_digest   TEXT NOT NULL,
  external_id      TEXT,
  result           BLOB,
  error            BLOB,
  fence            INTEGER NOT NULL,
  attempt_token    TEXT,
  attempt_deadline TEXT,
  updated_at       TEXT NOT NULL
);

CREATE INDEX idx_tamoz_effect_execution
  ON tamoz_effects (thread_id, ns, execution_id);

CREATE TABLE tamoz_requests (
  thread_id           TEXT NOT NULL,
  ns                  TEXT NOT NULL DEFAULT '',
  request_id          TEXT NOT NULL,
  enqueue_sequence    INTEGER NOT NULL,
  input_digest        TEXT NOT NULL,
  delivery_mode       TEXT NOT NULL,
  status              TEXT NOT NULL,
  payload             BLOB NOT NULL,
  execution_id        TEXT,
  target_execution_id TEXT,
  cancellation_gen    INTEGER,
  checkpoint_id       TEXT,
  response            BLOB,
  terminal_error      BLOB,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL,
  PRIMARY KEY (thread_id, ns, request_id),
  UNIQUE (thread_id, ns, enqueue_sequence)
);

CREATE INDEX idx_tamoz_request_queue
  ON tamoz_requests (thread_id, ns, status, enqueue_sequence);

CREATE TABLE tamoz_thread_tombstones (
  thread_id             TEXT PRIMARY KEY,
  tombstone_id          TEXT NOT NULL UNIQUE,
  expected_tips          BLOB NOT NULL,
  status                TEXT NOT NULL,
  effect_policy         TEXT NOT NULL,
  report                BLOB NOT NULL,
  created_at            TEXT NOT NULL,
  purge_after           TEXT
);

CREATE TABLE tamoz_schedules (
  schedule_id        TEXT NOT NULL,
  revision           INTEGER NOT NULL,
  definition_digest  TEXT NOT NULL,
  payload             BLOB NOT NULL,
  created_at          TEXT NOT NULL,
  PRIMARY KEY (schedule_id, revision)
);

CREATE TABLE tamoz_schedule_heads (
  schedule_id        TEXT PRIMARY KEY,
  current_revision   INTEGER NOT NULL,
  status             TEXT NOT NULL,
  next_fire_at       TEXT,
  updated_at         TEXT NOT NULL,
  FOREIGN KEY (schedule_id, current_revision)
    REFERENCES tamoz_schedules (schedule_id, revision)
);

CREATE TABLE tamoz_occurrences (
  occurrence_id       TEXT PRIMARY KEY,
  schedule_id         TEXT NOT NULL,
  schedule_revision   INTEGER NOT NULL,
  nominal_fire_at     TEXT NOT NULL,
  not_before          TEXT NOT NULL,
  status              TEXT NOT NULL,
  request_id          TEXT NOT NULL,
  owner_id            TEXT,
  fence               INTEGER,
  lease_expires_at    TEXT,
  execution_id        TEXT,
  evidence            BLOB,
  UNIQUE (schedule_id, schedule_revision, nominal_fire_at)
);

CREATE INDEX idx_tamoz_occurrence_due
  ON tamoz_occurrences (status, not_before);
```

Foreign keys and cascade behavior are enabled and tested. `PRAGMA integrity_check`,
backup/restore, WAL recovery, disk-full behavior, schema migration rollback, and file
descriptor stability are release gates.

## 8. Store

Store remains explicit cross-thread application data:

```ruby
put(namespace, key, value, if_version: nil, sensitive: false)
get(namespace, key)
delete(namespace, key, if_version: nil)
each(namespace, prefix: nil, limit: nil)
search(namespace, query:, filter: {}, limit: 10)
```

Writes return a version; compare-and-set prevents lost updates. `search` is an optional
capability advertised by `searchable?`. A store without an embedder supports exact,
prefix, and filter lookup and must never pretend that lexical search is semantic search.

Nodes and tools reach Store through `Context`. Tenant namespace prefixes are applied by the
session boundary and cannot be overridden by model-generated arguments.

Conversation history stays in checkpoints. Credentials stay in a credential provider.
Large files stay in the filesystem or object storage. Store is not a dumping ground for all
three.

Plan versions, reviews, step evidence, and verification events belong to the thread's
checkpoint history because they determine why execution was authorized. Cross-thread
learning uses dedicated Store namespaces for immutable trajectories, Experience, Knowledge,
Wisdom, memory transitions/contradictions/deletion receipts, improvement candidates,
evaluations, promotions, and behavior versions. Each record carries provenance,
content-policy metadata, artifact digests, and an optimistic version.

Candidate activation is compare-and-set against the active `behavior_version`. Promotion and
rollback append audit records; they never overwrite candidate evidence. Capability- or
policy-changing candidates also carry a human approval identity. Checkpoints persist the
active `behavior_version` so resume never silently adopts a newer prompt, heuristic, or
policy. New and rolled-back versions enter an existing thread only through an explicit
turn-boundary transition checkpoint.

Memory records are append-versioned. Active-state indexes are derived and rebuildable; they
are never the source of truth. Promotion, supersession, quarantine, correction, and deletion
use compare-and-set against the prior record version and append an audit transition.
Authorization filters are part of the query contract and execute before lexical/vector
ranking.

Self-healing rules are immutable application artifacts. Store persists rule activation
mode, failure fingerprints, plan/review linkage, attempts, verification/compensation
evidence, circuit state, reset decisions, and issue references. Remote mutations remain in
the effect journal. A circuit state and its triggering evidence commit atomically where
they guard the same thread; cross-thread rule circuits use Store compare-and-set and fail
closed on contention.

MCP server configurations, discovered capability snapshots, and skill snapshots are
immutable content-addressed artifacts. Store records configured ownership/trust, local
policy classification, protocol/source/tree/definition digests, epoch transitions,
availability, provenance, and evaluation evidence. Credentials and mutable remote/local
content remain outside the snapshot. Checkpoints persist the selected capability and skill
catalog digests so resume never substitutes a current server schema or changed skill tree.

Schedules and occurrences use the dedicated adapter contract rather than general Store
search. A schedule edit appends a revision under compare-and-set. Occurrence identity and
the unique key `(schedule_id, revision, nominal_fire_at)` survive duplicate scanners.
Creating/claiming an occurrence and its stable request id is one transaction or a durable
outbox; enqueue retries reuse that id. Delivery state is never used as graph completion
state.

## 9. Retention and recovery

- active threads keep every checkpoint by default;
- pruning is explicit, dry-runnable, and returns an audit report;
- pinned, fork-source, interrupt, effect-unknown, first, and latest checkpoints survive any
  default policy;
- deleting a thread first tombstones new work, preserves the late effect receipt sink, and
  handles pending writes, leases, effects, requests, and Store data according to an explicit
  caller-selected scope; purge occurs only after nonterminal effects are reconciled or
  explicitly abandoned with proof;
- deleting a schedule tombstones future delivery while preserving immutable revisions and
  occurrence history; it does not imply cancellation of an already-running execution;
- backup restore is tested, not documented only;
- corrupted records are quarantined and reported. The adapter never skips them and returns
  a later snapshot as if history were intact.

The in-memory adapter is for deterministic tests and ephemeral graphs. It cannot be used to
claim crash durability or effect safety.
