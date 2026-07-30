# `tamoz-graph` — the durable engine

The engine is a Bulk Synchronous Parallel runtime. Nodes read one immutable state snapshot,
execute concurrently, buffer writes, and commit one reducer-mediated next state at a
barrier.

The product is not the loop. It is the 55 invariants, persistence algebra, ownership model,
and explicit limits around external effects.

No LLM or provider appears in this gem.

## 1. Definition and compilation

```ruby
# Illustrative
definition = Tamoz.graph(name: "review", version: "1") do
  state :message_events, reduce: Tamoz::Reducers.message_events,
                         default: Tamoz::Defaults.empty_array
  state :findings, reduce: :union, default: -> { [] }
  state :status
  state :remaining_steps, managed: Tamoz::Managed::RemainingSteps

  node :plan, Plan
  node :analyse, Analyse, retry: { attempts: 3, on: [TransientError] }
  node :review, Review

  edge START, :plan
  edge :plan, :analyse
  branch :analyse, version: "1" do |state|
    state[:findings].empty? ? END : :review
  end
  edge :review, END
end

app = definition.compile(
  checkpointer: sqlite,
  store: sqlite.store,
  effects: sqlite.effects
)
```

The builder collects declarations. `compile`:

- validates node/edge targets, reachability, reducer names, managed channels, and routing;
- requires a graph name and version for durable compilation;
- canonicalizes structural declarations and computes `definition_digest`;
- validates defaults and initial input through the state codec;
- binds runtime policies and returns an immutable compiled graph.

Durable graphs require stable identities/versions for block nodes, branches, reducer
lambdas, and default factories. Built-in/registered reducers carry these identities.
Anonymous behavior without an explicit version is allowed only for ephemeral compilation.

Code blocks cannot be meaningfully hashed across builds. The digest therefore covers stable
node/router/reducer/default names plus explicit implementation versions, not Ruby bytecode:

```ruby
node :analyse, Analyse, version: "3"
```

Changing behavior without changing the node or graph version is an application bug caught
by review tooling and migration tests. Durable resume compares declared identity and digest
before user code runs.

`START` and `END` are virtual markers.

## 2. State and reducers

State is a schema-declared Hash. Nodes return partial updates.

| Channel | Declaration | Behavior |
|---|---|---|
| Last value | no reducer | zero/one write per step; multiple writes fail |
| Reducer | lambda or registered symbol | receives one ordered batch of all writes |
| Topic | `topic: true` | append-only packets consumed by scheduler |
| Managed | managed class | engine-computed and read-only to nodes |

Built-ins are minimal: `:append`, `:merge`, `:union`, `:max`, `:min`, message log, and usage
ledger. `:last_value` is the absence of a reducer, not a reducer that hides conflicts.

Reducer contract:

```ruby
reduce(current_value, ordered_writes) -> next_value
```

Passing the whole batch makes barrier atomicity visible and testable. A reducer must be
deterministic and pure. Commutativity is required only when the schema declares
`order: :arbitrary`; the default order is stable task path. Associativity is still tested
for built-ins.

Committed state is normalized, copied, and recursively frozen once per barrier. The same
snapshot is shared by tasks. Arbitrary mutable objects are rejected for durable graphs.

### Message history

The agent message reducer is an append-only event log:

- a new message id appends;
- an edit is a new revision event referencing the original id;
- a removal is a tombstone event;
- compaction appends a summary/epoch event;
- a deterministic projection materializes the model-visible history.

This preserves audit history and prompt-cache reasoning. Generic nodes cannot silently
upsert old message content.

### Usage

Usage is not a Hash merge. `Reducers.usage` records per-model-call usage by deterministic
effect key and derives totals. Replayed receipts therefore do not double-count cost.

## 3. Super-step protocol

```text
invoke / stream(input, thread:, request_id:)
  │
  ├─ acquire lease for (thread_id, ns); obtain fence
  ├─ claim request/execution; load CheckpointView or create input checkpoint
  ├─ reject incompatible graph/format
  │
  └─ loop
       PLAN
         derive ordered tasks from checkpoint + pending writes + definition
         stop when no tasks; enforce step budget; apply static breakpoints
       EXECUTE
         pool runs tasks against the same frozen snapshot
         each worker catches its own :tamoz_interrupt
         each worker returns Success, Interrupted, Failed, or Cancelled
         successful writes append durably and idempotently
       RESOLVE
         if fatal failure: retain successful pending writes and fail
         if interrupts: persist all interrupt descriptors and pause
         otherwise group writes by channel and reduce once
       COMMIT
         compare base checkpoint + fence
         atomically append exactly one next checkpoint
         associate consumed pending writes
         emit checkpoint part only after storage commit
       renew lease and repeat
```

The coordinator never mutates the committed snapshot. A failed commit discards the
candidate next state and reloads or fails; it never keeps running on uncommitted memory.

Committed checkpoint durability is synchronous for durable graphs. Ephemeral graphs use the
memory/null adapter and make no crash guarantee. v0.1 has no “async durable” mode whose
acknowledged checkpoint can disappear.

## 4. Planning and task identity

Planning is a pure function of:

```text
(definition_digest, checkpoint, pending_writes)
```

PULL tasks are triggered by channel versions not yet recorded in `versions_seen`. PUSH
tasks come from `Send` packets in a topic channel.

Every task has:

```ruby
Task = Data.define(
  :id,                 # stable logical activation id
  :attempt_id,         # one invocation attempt from one base checkpoint
  :execution_id,
  :node,
  :path,
  :kind,
  :input,
  :attempt,
  :activation_checkpoint_id,
  :base_checkpoint_id
)
```

`id` identifies one **logical activation**, not an invocation attempt. When a task first
becomes eligible, its id is a stable digest over graph identity, execution id, the checkpoint
that created the activation, logical step, kind, and full task path. The complete task
descriptor, including `activation_checkpoint_id`, is persisted. Interrupt, retry, crash
resume, and lease takeover reuse it.

`attempt_id` is a separate digest over task id, attempt number, and the checkpoint from which
that invocation starts. A resumed node therefore keeps its task/effect/interrupt identity
while receiving a new attempt identity that the barrier can validate against the new base.
A new turn or fork creates a new execution id and cannot inherit activations, pending writes,
or effects accidentally. Fan-out indices derive from declared `Send` order, never completion
order. Golden fixtures pin both recipes.

Pending results and interrupt resume values are matched by stable task id. Their stored
attempt/base fields are provenance, not identity. On restart, already recorded successful
tasks are not invoked again. A task that ran an effect but did not record its result is
governed by the effect journal, not wishful “exactly once” scheduling.

## 5. Execute and barrier semantics

The pool may complete tasks in any order. The coordinator commits in task-path order:

1. reject a newly returned task result whose attempt id or base checkpoint differs from the
   scheduled attempt;
2. sort task results by path;
3. group writes by state key;
4. call each channel once with its entire ordered batch;
5. update channel versions and `versions_seen`;
6. normalize/freeze the candidate state;
7. atomically compare-and-append the checkpoint.

Parallel writes to a reducer-less key fail before commit and name all writers.

An unhandled node exception becomes `Tamoz::NodeError` with graph, node, task, attempt, and
the original exception/backtrace. Successful sibling writes remain pending so resume can
reuse them. Programmer and policy failures are never downgraded to model-facing values.

The barrier serializes state mutation. It does not remove the need for a durable lease:
without one, two coordinators could independently plan from the same base checkpoint.

## 6. `Command`, routing, and `Send`

```ruby
Tamoz::Command = Data.define(:update, :goto, :resume, :graph)
Tamoz::Send = Data.define(:node, :input, :key)
```

Node returns:

| Value | Meaning |
|---|---|
| Hash | partial update |
| `Command(update:, goto:)` | update plus dynamic routing |
| `Command(goto: [Send...])` | dynamic fan-out |
| `Command(goto:, graph: :parent)` | explicit parent routing |
| nil | no update |

Static successors and `Command#goto` are additive. Because Ruby cannot infer a block's
possible return type, `compile` cannot reliably warn from a “Command-returning signature.”
The builder instead accepts explicit intent:

```ruby
node :dispatch, Dispatch, routing: :additive
```

Returning `Command#goto` from a node with static successors without `routing: :additive`
raises a definition error. This preserves the semantic while making surprising routing
visible.

Every `Send` has a stable `key`; if omitted, the compiler derives one from its declared
array position. Callers should provide keys when fan-out inputs come from an unordered
source.

## 7. Interrupt and resume

```ruby
def call(state, context)
  plan = build_plan(state)
  answer = Tamoz.interrupt({ kind: :approve_plan, plan: plan }, context)
  answer == :approve ? { plan: plan } : { status: :abandoned }
end
```

`Tamoz.interrupt` performs `throw :tamoz_interrupt, descriptor`. Each worker surrounds node
execution with the matching `catch`. The worker converts the thrown descriptor into
`TaskResult::Interrupted`, which the coordinator persists at the barrier.

This placement is mandatory. Ruby's catch is stack-local; a catch in the coordinator cannot
receive a throw from a thread-pool worker.

Resume rules:

- the node restarts from its first line;
- values match `(task_id, call_index)` where task id is the stable logical activation id;
- call order before the pause must remain stable;
- multiple parallel interrupts are returned together and may be resumed by task-id map;
- pre-interrupt effects must use `Context#effects` or be pure/idempotent;
- resuming uses a stable external `request_id` so duplicate delivery is harmless.

Static `interrupt_before` and `interrupt_after` are planned barrier events, not worker
throws.

## 8. External effects

Nodes are replayable computations. External effects require an explicit wrapper:

```ruby
result = context.effects.run(
  :write_file,
  safety: :idempotent,
  idempotency_key: digest(path, content)
) do |effect|
  atomic_write(path, content, idempotency_key: effect.key)
end
```

The effect key includes execution id, stable logical task id, and call index; it deliberately
does not include attempt id or the mutable resume checkpoint. The wrapper consults the journal:

- succeeded → return recorded result;
- safe incomplete → retry with the same key;
- reconcilable → query the target and record the outcome;
- unsafe/ambiguous → emit `:effect_unknown` and interrupt for resolution.

Approval and effect identity are separate. Approval authorizes an operation; it does not
make the operation idempotent.

Pure graph users can ignore the effect API. `tamoz-agent` requires tools to declare an effect
safety class.

## 9. Threads, replay, fork, and input deduplication

- A thread is append-only history under `(thread_id, ns)`.
- One fenced lease owns advancement.
- `state(thread:)` returns the latest snapshot, pending tasks, interrupts, graph identity,
  and effect-unknown records.
- `history` streams snapshots newest-first.
- replay/fork from a checkpoint creates a new execution id and appends a new active branch
  tip; it never mutates the old chain or silently reuses source pending writes/effects.
- `update_state` runs reducers and creates a fork checkpoint when based on history.
- every external input has `request_id`; duplicates return the existing turn outcome or
  join the active run.

The durable request inbox is stored with the thread so CLI retries, gateway redelivery, and cron
restarts do not append the same user turn twice.

Re-running external effects on an intentional fork is an explicit policy decision. The
default reuses no source receipt and blocks effect-bearing replay until the caller chooses
skip, re-execute with a new effect identity, or supply a reconciled result.

## 10. Subgraphs

A compiled graph implements `#call`, so it can be a node. Persistence modes are explicit:

| Mode | Meaning |
|---|---|
| `:invocation` | fresh logical state per call; inherits parent backend/namespace for durability |
| `:thread` | state persists across calls under the same subgraph namespace |
| `:none` | stateless/ephemeral; interrupts and crash resume unavailable |

No subgraph creates its own backend implicitly. Parent and child share the top-level
checkpointer, lease family, and effect journal under deterministic namespaces. Subgraph
streams retain the namespace path.

Interrupts bubble as typed task results. On resume, parent and child nodes restart according
to their recorded task boundaries.

## 11. Execution-output streaming and cancellation

`stream` returns an Enumerator over the one run:

```ruby
app.stream(input, thread: id, request_id:, mode: %i[updates messages tasks])
```

Modes select projections, not execution paths. Live task/progress events can arrive in
completion order. Checkpoint, state, and model-facing message order are deterministic.

Stopping enumeration requests cooperative cancellation. The last committed checkpoint
remains valid. In-flight external effects may still complete and are resolved by their
journal records. Late task state is never committed after lease loss or cancellation.

## 12. Limits

Each run has independent ceilings for:

- super-steps;
- wall-clock deadline;
- concurrent tasks;
- total scheduled tasks;
- serialized state bytes;
- pending-write bytes;
- stream-buffer capacity.

The agent layer adds token, cost, tool-output, and subagent budgets. Limit errors name the
observed value, configured ceiling, graph, and thread-safe user message.

## 13. Explicit non-responsibilities

The engine does not own:

- model/provider selection or prompting;
- tool approval policy or model-facing error formatting;
- memory curation or compaction policy;
- exactly-once arbitrary external effects;
- UI, gateway, cron, authentication, or tenant authorization;
- multi-agent topology classes.
