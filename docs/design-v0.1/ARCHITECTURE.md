# Architecture

Runtime boundaries, dependency rules, and the shape of the v0.1 product.

## 1. The v0.1 stack

Four runtime gems, one development/release evaluation gem, one application, and one
direction of production dependency.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Tamoz Agent             reference CLI agent                              │ app
└───────────────┬───────────────────────────────┬──────────────────────┘
                ▼                               ▼
┌───────────────────────────────┐  ┌───────────────────────────────────┐
│ tamoz-agent                    │  │ tamoz-sqlite                       │
│ plan/review · durable ReAct   │  │ checkpoint · lease · effects     │
│ verify · memory · heal        │  │ Store                            │
└───────┬───────────────┬───────┘  └─────────────────┬─────────────────┘
        │               └──────────────▶ ruby_llm     │
        │                                             │
        └────────────────────────┬────────────────────┘
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ tamoz-graph         state graph · BSP engine · interrupts · replay    │
├──────────────────────────────────────────────────────────────────────┤
│ tamoz-core          Context · StreamPart · errors · instrumentation    │
└──────────────────────────────────────────────────────────────────────┘

  tamoz-evals ──▶ exercises every public boundary and Tamoz Agent
                 development/release only; never a production dependency
```

Candidate extensions are deliberately outside the v0.1 commitment:

- `tamoz-chain` — promote only when a shipped application needs more than ordinary Ruby
  functions and graphs;
- `tamoz-rails` / `tamoz-activerecord` — promote when Rails-first is chosen or a real Rails
  consumer exists;
- channel, vector-store, and observability adapters — separate gems with their own owners.

Three post-v0.1 packages now have accepted designs and concrete Tamoz Agent consumers:

- `tamoz-mcp` — official-SDK-backed MCP host/server integration, governed by
  [MCP_DESIGN.md](MCP_DESIGN.md);
- `tamoz-scheduler` — durable occurrence generation into the request inbox, governed by
  [SCHEDULER_DESIGN.md](SCHEDULER_DESIGN.md);
- `tamoz-stream` — deterministic unbounded evidence into immutable Situations and bounded
  agent episodes, governed by [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md).

This is smaller than the original seven-plus-gem proposal. The reference application did
not consume several proposed packages, so publishing them would violate the rule that every
framework abstraction needs a demanding consumer.

## 2. Dependency rules

The rules are executable dependency tests:

1. **`tamoz-core` has no runtime dependency beyond the standard library and Zeitwerk.**
2. **`tamoz-graph` never references RubyLLM, HTTP, a provider SDK, or an adapter.** A clean
   process requiring `tamoz/graph` must leave those constants unloaded and open no socket.
3. **`tamoz-agent` is the only v0.1 layer that knows RubyLLM.** It accepts
   `RubyLLM::Agent`, `RubyLLM::Chat`, or a callable that produces a chat. It reuses their
   public messages and tools without provider-specific branches in Tamoz.
4. **Adapters implement published contracts and depend on core/graph, never on runner
   internals.**
5. **Optional dependencies load only when their feature is selected.** Fiber execution,
   OpenTelemetry, and future Rails integration must not affect a minimal boot.
6. **No mutable process-global runtime state.** Boot-time registries freeze after
   configuration. Per-run state travels through `Context`; per-thread durable state travels
   through the checkpointer.
7. **No runtime gem or application runtime depends on `tamoz-evals`.** The eval gem may
   exercise their public APIs in development and release jobs. Removing it from a production
   bundle cannot change execution or loading.
8. **MCP, scheduling, and streaming input are optional runtime packages.** None is required by
   `tamoz-core`, `tamoz-graph`, `tamoz-agent`, or a minimal `tamoz-sqlite` boot. `tamoz-mcp`
   uses the official `mcp` SDK; `tamoz-scheduler` delivers stable requests through
   published persistence contracts; `tamoz-stream` depends only on core values and never
   loads a model on its deterministic path.
9. **Optional persistence protocols are structural and versioned.** The feature gem owns
   the ScheduleStore or StreamStore contract documentation and conformance version.
   `tamoz-sqlite` implements those methods without referencing feature-gem constants and
   loads its optional schema/module only when explicitly required. `tamoz-evals` loads both
   gems and runs their version-pair compatibility suite. No reverse runtime dependency or
   require cycle is permitted.

Rule 2 is invariant 11. It keeps the graph conformance suite offline and makes the runtime
useful for durable non-LLM workflows.

## 3. Ownership by package

### `tamoz-core`

Owns only values and dispatch shared across boundaries:

- `Tamoz::Context`, including cancellation, deadlines, event emission, Store access, and an
  effect journal;
- `Tamoz::StreamPart` and the bounded stream sink;
- operational and programmer-error taxonomies;
- notifier and clock protocols;
- ordered pools for inline, thread, and optional fiber execution.

It does not own graph state, messages, tools, persistence, retries, or provider behavior.

### `tamoz-graph`

Owns the deterministic execution semantics:

- graph definition, compilation, and definition digest;
- state schema, channels, reducers, immutable snapshots;
- PLAN → EXECUTE → COMMIT super-steps;
- deterministic task identities and ordered result reduction;
- checkpoint, lease, and Store contracts;
- interrupt/resume, `Command`, `Send`, replay, fork, and subgraphs;
- effect identity and outcome semantics, but no domain-specific tools;
- stream projection from the one execution path.

The engine guarantees atomic committed state. It does not claim exactly-once external
effects.

### `tamoz-sqlite`

Owns one production adapter:

- append-only checkpoints and idempotent pending writes;
- atomic compare-and-append commit;
- per-thread leases with monotonically increasing fencing tokens;
- effect journal records;
- cross-thread Store;
- migrations, retention, WAL configuration, bounded connections, backups, and integrity
  checks.

SQLite serializes writers even in WAL mode. Tamoz therefore keeps write transactions short,
uses `BEGIN IMMEDIATE` where appropriate, retries `SQLITE_BUSY` with bounded jitter, and
never holds a transaction across a model or tool call.

### `tamoz-agent`

Owns recipes over the graph:

- the durable model ↔ tools graph;
- the RubyLLM adapter boundary;
- tool result ordering, approval, effect classification, output bounding, and cancellation;
- mandatory plan/review/verification gates and adaptive replanning;
- subagent recipes, model policy, token/cost budgets, compaction, and skills;
- one locally governed, content-addressed capability catalog across local tools, MCP, and
  skills;
- Experience/Knowledge/Wisdom memory lifecycle and retrieval protocols;
- bounded remediation recipes over typed failures, effect safety, verification, and circuits;
- versioned improvement candidates, evaluation/promotion contracts, and behavior rollback;
- prompt-cache epoch assembly.

RubyLLM's `Agent` is reusable chat configuration. Tamoz's agent layer is durable execution.
The former is accepted as input to the latter; Tamoz does not create a competing provider or
configuration abstraction.

### `tamoz-evals`

Owns the executable invariant suites, behavioral cases, versioned evaluation artifacts,
baseline comparison, and release gates described in [EVALS_DESIGN.md](EVALS_DESIGN.md).
It may load runtime gems as subjects but contributes no runtime policy, instrumentation
backend, or provider abstraction. It ships `tamoz-eval` and is excluded from production
dependency groups.

### `tamoz-mcp` (post-v0.1)

Owns MCP protocol profiles over the official Ruby SDK, connection supervision, discovery
normalization, source-qualified capability descriptors, schema/content validation, and
mapping MCP calls into Tamoz tool/effect/interrupt contracts. Remote metadata never owns
local authorization, trust, or effect safety.

### `tamoz-scheduler` (post-v0.1)

Owns strict schedule values, time/DST/misfire/overlap calculation, durable occurrence
identity, due claiming, and enqueue into the request inbox. It never executes an agent or
interprets success. It publishes the structural ScheduleStore contract and conformance
version; `tamoz-sqlite` implements its first schedule/occurrence store through an
explicitly loaded optional module.

### `tamoz-stream` (first post-v0.1 product milestone)

Owns authenticated channel admission, event identity, deterministic virtual partitions,
event time, watermarks, bounded windows/timers, immutable Situation versions, cognition
admission, and replay. It never sends raw unbounded evidence to a model and never executes a
physical effect. `tamoz-sqlite` implements its first StreamStore; broker/device adapters
remain separate. `tamoz-stream` owns the structural StreamStore contract and conformance
version; neither gem requires the other during minimal boot.

### Tamoz Agent

Tamoz Agent owns product policy and all user-facing surfaces. In v0.1 it is CLI-only. It owns
filesystem roots, command approval policy, session identity, redaction policy, and the
choice to queue or redirect concurrent input. It also owns the thresholds for critic/human
plan review and the authority policy that decides which evaluated improvements may activate
automatically. It owns memory scope/sensitivity/retention/promotion policy and the enabled
self-healing rule registry. It also owns MCP server admission/export policy, skill sources
and bindings, scheduled-task grants/approval/delivery policy, channel bindings, Situation
policies, and the deployment-specific physical action ceiling. The reusable framework
enforces those decisions but does not invent them. External functional-safety controllers
and interlocks remain authoritative.

## 4. One execution protocol

The stack has several contracts; it does not pretend they are one interface. It does have
one execution protocol:

```ruby
# Illustrative
step.call(input, context)
```

A graph node receives frozen state as `input` and returns a partial update or `Command`.
A chain-like step receives an ordinary value. A compiled graph also implements this
protocol, so it can be nested.

A two-argument `Proc` is adaptable through `Tamoz.step { |input, context| ... }`. Native
`Proc#>>` is not the framework's composition operator: Ruby forwards the first Proc's result
to the second Proc as one argument and therefore loses `context`. `Tamoz.seq` is the
canonical explicit composition API if `tamoz-chain` is promoted.

The other contracts are intentionally separate because they have different failure
semantics:

| Contract | Essential operation |
|---|---|
| Checkpointer | load, append task writes, compare-and-append a checkpoint |
| Lease | acquire, renew, release with a fencing token |
| Effect journal | prepare with an attempt token, complete/reconcile an external effect |
| Request ledger | claim and complete a surface input by stable request id |
| Schedule/occurrence store | revise schedules, claim due occurrences, enqueue stable requests |
| StreamStore | admit events, advance partition state, append Situations/admissions/outcomes |
| Store | explicit cross-thread application data |
| Notifier | observe an event without influencing behavior |
| Stream sink | deliver a behaviorally relevant event with backpressure |

## 5. The execution boundary

The coordinator plans a super-step from one committed checkpoint. Each task runs inside its
own worker boundary:

```text
coordinator
  ├─ acquire/renew fenced thread lease
  ├─ plan ordered Task descriptors
  ├─ pool executes each task
  │    └─ worker-local catch(:tamoz_interrupt)
  │         ├─ value     → TaskResult::Success
  │         ├─ throw     → TaskResult::Interrupted
  │         └─ exception → TaskResult::Failed
  ├─ durably append successful task writes
  └─ atomically commit one next checkpoint if base id + fence still match
```

`throw`/`catch` remains a useful Ruby choice because ordinary `rescue` cannot swallow the
pause. The matching `catch` must be in the same worker execution stack. A coordinator-level
catch cannot receive a throw from another thread.

## 6. State, checkpoints, effects, and Store

Four concerns must not be conflated:

| Concern | Scope | Guarantee |
|---|---|---|
| State | one committed graph snapshot | immutable input; reducer-mediated updates |
| Checkpoint | one graph thread | append-only, atomic durable history |
| Effect journal | one external operation | replay decision: completed, safe retry, or unknown |
| Store | across graph threads | mutable application memory, explicitly accessed |

The effect journal is separate because a checkpoint cannot atomically commit an arbitrary
remote operation. The runtime assigns every effect a deterministic key
`(thread_id, ns, execution_id, logical_activation_id, call_index, operation)`. Attempt id
and resume checkpoint are deliberately excluded. The target operation must then be:

- read-only;
- idempotent under that key;
- transactionally committed with the journal;
- reconcilable after ambiguity; or
- rejected from automatic durable execution.

This is the difference between durable state and honest durable behavior.

## 7. Execution-output streaming and observability

One execution produces state transitions, stream parts, and observer events:

- **State/checkpoints** are load-bearing.
- **Stream parts** are consumer-facing and may carry interrupts or progress.
- **Instrumentation** is observer-only and may be dropped without changing behavior.

Parallel workers publish through a bounded sink. The public API is a lazy `Enumerator`, but
the implementation uses a bounded queue because worker threads cannot safely yield into the
consumer's enumerator. Closing the enumerator cancels the producer, closes the sink, and
joins owned workers. Slow consumers apply backpressure; they cannot cause unbounded memory
growth.

Committed state and checkpoint bytes are identical whether stream consumption is enabled or
not. Live progress ordering may differ; committed updates and model-facing tool messages
are ordered deterministically.

Instrumentation payloads contain ids, names, status, counts, and durations by default.
Prompts, tool arguments/results, file contents, and secrets require an explicit
content-capture policy.

## 8. Version and ownership boundaries

Every checkpoint records:

- `format_version` — serializer/storage compatibility;
- `graph_name` and `graph_version` — application-declared compatibility;
- `digest_version` — canonicalization/hash recipe;
- `definition_digest` — canonical state schema, nodes, edges, reducers, and interrupt
  configuration;
- `sequence` — strict order within `(thread_id, ns)`;
- `execution_id` — stable across resume, new across turns/forks;
- `fence` — the lease generation that committed it.

Resume fails before running user code if versions or digests are incompatible. Migrations
are explicit, versioned functions that produce a new checkpoint; history is never mutated.

Digests use a stored algorithm/canonicalization version and domain-separated SHA-256 over
canonical UTF-8 JSON. They never depend on Ruby object ids, Hash insertion accidents, file
paths, or source locations.

Only one live lease may advance a `(thread_id, ns)`. Every append validates both the base
checkpoint id and fencing token. A stale runner can finish a remote call, but it cannot
commit state after losing ownership.

## 9. File layout

Zeitwerk-loaded, with public values separate from execution internals:

```text
tamoz-graph/
  lib/tamoz/graph.rb
  lib/tamoz/graph/
    builder.rb  compiled.rb  definition.rb  definition_digest.rb
    state_schema.rb  channel.rb  reducer.rb  immutable_snapshot.rb
    planner.rb  task.rb  task_result.rb  executor.rb  barrier.rb
    checkpoint.rb  checkpoint_view.rb  checkpointer.rb  lease.rb
    effect.rb  effect_journal.rb
    command.rb  send.rb  interrupt.rb  snapshot.rb
    stream/sink.rb  stream/projection.rb

tamoz-evals/
  lib/tamoz/evals.rb
  lib/tamoz/evals/
    case.rb  suite.rb  runner.rb  result.rb  gate.rb
    scorers/  judges/  reporters/  conformance/
  schemas/
  suites/
  exe/tamoz-eval

tamoz-stream/                         # first post-v0.1 milestone
  lib/tamoz/stream.rb
  lib/tamoz/stream/
    channel_descriptor.rb  envelope.rb  admission.rb  connector.rb
    partition.rb  watermark.rb  window.rb  timer.rb  operator.rb
    situation_spec.rb  situation.rb  situation_snapshot.rb
    trigger_evaluation.rb  cognition_admission.rb  replay.rb
    decision.rb  action_intent.rb  command_policy.rb  stream_store.rb
```

The coordinator may fit in a few hundred lines. Readability is a review constraint, not a
line-count target that just moves semantics into helpers.
