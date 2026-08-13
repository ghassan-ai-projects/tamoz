# The durable graph engine (`tamoz-graph`)

`tamoz-graph` is the durable execution engine at the heart of Tamoz: a Bulk Synchronous Parallel (BSP) runtime in which nodes read one immutable state snapshot, execute concurrently, buffer writes, and commit one reducer-mediated next state at a barrier.

The engine is not the agent loop. Its contract is deterministic execution, a persistence algebra, an ownership model, and explicit limits around external effects. Source: [`docs/design-v0.1/GRAPH_DESIGN.md`](../../docs/design-v0.1/GRAPH_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## Bulk Synchronous Parallel execution

A run is a loop of four phases:

```text
PLAN      derive ordered tasks from checkpoint + pending writes + definition
EXECUTE   pool runs tasks against the same frozen snapshot
RESOLVE   group writes by channel and reduce once; persist interrupts on pause
COMMIT    compare base checkpoint + fence; atomically append exactly one next checkpoint
```

- The coordinator never mutates the committed snapshot. A failed commit discards the candidate next state and reloads or fails; it never keeps running on uncommitted memory.
- Parallel writes to a reducer-less key fail before commit and name all writers.
- Committed checkpoint durability is synchronous for durable graphs; ephemeral graphs make no crash guarantee. There is no "async durable" mode whose acknowledged checkpoint can disappear.
- The pool may complete tasks in any order; the coordinator commits in deterministic task-path order.
- Every run has independent ceilings: super-steps, wall-clock deadline, concurrent tasks, total scheduled tasks, serialized state bytes, pending-write bytes, and stream-buffer capacity.

## State and reducers

State is a schema-declared Hash. Nodes return partial updates; a reducer receives the whole ordered batch of a channel's writes at the barrier:

```ruby
reduce(current_value, ordered_writes) -> next_value
```

Channel kinds: last value (no reducer; zero/one write per step), reducer (one ordered batch), topic (append-only packets consumed by a scheduler), and managed (engine-computed, read-only to nodes). Built-in reducers are minimal: `:append`, `:merge`, `:union`, `:max`, `:min`, the message log, and a usage ledger that deduplicates replayed cost receipts.

Committed state is normalized, copied, and recursively frozen once per barrier; the same snapshot is shared by all tasks. Arbitrary mutable objects are rejected for durable graphs.

## Interrupts

`Tamoz.interrupt` performs `throw :tamoz_interrupt, descriptor`; each worker surrounds node execution with the matching `catch` (a coordinator catch cannot receive a throw from a pool worker). The worker converts the descriptor into a paused task result that the coordinator persists at the barrier. Resume rules:

- the node restarts from its first line;
- resume values match `(task_id, call_index)` where the task id is a stable logical activation id;
- call order before the pause must remain stable;
- multiple parallel interrupts are returned together and may be resumed by task-id map;
- pre-interrupt external effects must go through the effect wrapper or be pure/idempotent;
- resume uses a stable external `request_id` so duplicate delivery is harmless.

Static `interrupt_before`/`interrupt_after` are planned barrier events, not worker throws.

## Task identity and the durable-runner contract

Planning is a pure function of `(definition_digest, checkpoint, pending_writes)`. Every task carries a stable logical **activation id** (a digest over graph identity, execution id, checkpoint, logical step, kind, and task path) plus a separate **attempt id** bound to the base checkpoint. Interrupt, retry, crash resume, and lease takeover reuse the activation id; the barrier validates the attempt against the current base.

The runner contract for a durable request:

- acquire a fenced lease for `(thread_id, ns)`, claim the request/execution, and load the checkpoint view;
- reject incompatible graph or format versions before user code runs;
- replay completed tasks from the journal rather than invoking them again; a task that ran an effect but did not record its result is governed by the effect journal, not wishful exactly-once scheduling;
- on resume, keep the same execution id so one logical turn stays one trace.

## External effects

Nodes are replayable computations; external effects require an explicit wrapper:

```ruby
result = context.effects.run(:write_file, safety: :idempotent,
  idempotency_key: digest(path, content)) { |effect| ... }
```

The effect key includes execution id, stable logical task id, and call index — never the attempt id. The wrapper consults the journal: succeeded → return the recorded result; safe incomplete → retry with the same key; reconcilable → query the target and record the outcome; unsafe or ambiguous → emit `:effect_unknown` and interrupt for resolution. Approval authorizes an operation; it does not make it idempotent.

## Replay, fork, and input deduplication

- A thread is append-only history under `(thread_id, ns)`, advanced by one fenced lease.
- `state(thread:)` returns the latest snapshot, pending tasks, interrupts, graph identity, and effect-unknown records; `history` streams snapshots newest-first.
- Replay/fork from a checkpoint creates a new execution id and appends a new active branch tip; it never mutates the old chain or silently reuses source pending writes or effects. Re-running external effects on a fork is an explicit policy decision — the default reuses no source receipt and blocks effect-bearing replay until the caller chooses skip, re-execute with a new effect identity, or supply a reconciled result.
- Every external input carries a `request_id`; duplicates return the existing turn outcome or join the active run. The durable request inbox stores the request with the thread so CLI retries, gateway redelivery, and scheduler restarts do not append the same user turn twice.

## Subgraphs

A compiled graph implements `#call`, so it can be a node. Persistence modes are explicit:

| Mode | Meaning |
|---|---|
| `:invocation` | fresh logical state per call; inherits the parent backend/namespace for durability |
| `:thread` | state persists across calls under the same subgraph namespace |
| `:none` | stateless/ephemeral; interrupts and crash resume unavailable |

No subgraph creates its own backend implicitly; parent and child share the top-level checkpointer, lease family, and effect journal under deterministic namespaces. Interrupts bubble as typed task results.

## Checkpoints as immutable Data

A checkpoint is an immutable value type — `Checkpoint = Data.define(...)` — carrying `format_version`, `sequence`, `thread_id`, `namespace`, `execution_id`, `parent_id`, graph name/version, `definition_digest`, `status`, `logical_step`, the frozen state, pending writes, interrupts, resume values, and attempts. Backend-assigned integer sequence orders checkpoints within `(thread_id, ns)`; correctness never depends on wall-clock or lexical ordering. Resume is graph-version checked: an incompatible checkpoint fails before user code unless an explicit migration appends a compatible one.

## The no-LLM rule (invariant 11)

**`tamoz-graph` never loads an LLM client.** Requiring `tamoz-core`/`tamoz-graph` pulls in no RubyLLM, HTTP client, provider, or adapter. The engine is a general durable-execution runtime that happens to be used for agents; this keeps it testable offline and reusable for non-LLM workflows. No LLM or provider appears in the gem.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../overview/concepts.md`](../overview/concepts.md) — threads, checkpoints, and requests in context
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract, including the no-LLM rule
- [`../reference/public-api.md`](../reference/public-api.md) — the public `tamoz-graph` surface
- [`../../docs/design-v0.1/GRAPH_DESIGN.md`](../../docs/design-v0.1/GRAPH_DESIGN.md) — the authoritative design record
