# M1 implementation plan — core contracts

Status: implemented and deep-reviewed; implementation began only after the review checklist
below passed.

M1 implements the dependency-light contracts in `tamoz-core`. It does not implement graph
definition, reducers, checkpoints, interrupts, effects, persistence, model integration, or
agent behavior. Those remain M2 and later milestones.

## Outcome

M1 provides a small, production-quality substrate that later packages can share without
ambient tenant state or optional runtime dependencies:

- an immutable supported-value boundary and versioned, allowlisted JSON state codec;
- explicit secrets that are rejected by persistence and execution streams;
- typed errors with safe operational metadata;
- Context, monotonic deadlines, cooperative cancellation, configuration, and
  observer-only instrumentation;
- immutable StreamPart values and a bounded, one-consumer StreamSink;
- ordered inline and thread pools with bounded work queues and typed task results.

Runtime dependencies remain Ruby standard library and Zeitwerk only. `tamoz-core` must load
without `tamoz-graph`, `tamoz-evals`, persistence, provider, network, or model code.

## Public contract

### Values and serialization

- `Tamoz::Secret` stores a sensitive value, exposes it only through explicit `#reveal`, and
  redacts `#inspect` and `#to_s`.
- `Tamoz::StateCodec` emits the versioned wire envelope
  `["tamoz.state", 1, encoded_value]`.
- Built-in values are nil, booleans, integers, finite floats, UTF-8 strings, arrays, and
  hashes with string or symbol keys. Symbol keys serialize as strings and load as strings;
  colliding string/symbol keys fail.
- Registered immutable values use constructor-supplied registrations containing a stable
  tag, positive version, exact class, encoder, decoder, and explicit immutability predicate.
  The decoded value must match the exact class and pass that predicate. Core does not pretend
  it can introspect arbitrary adapter internals. Registration returns a new codec; there is
  no mutable global type registry.
- Decoding validates the complete wire tree, all tags/versions, UTF-8, collection/depth/byte
  limits, and payload shapes before invoking any registered decoder.
- Unknown formats, unknown tags/versions, cycles, unsupported objects, non-finite numbers,
  invalid UTF-8, excessive input, and `Tamoz::Secret` fail closed.
- Decoded core containers are recursively immutable. Registered values satisfy their
  registration's explicit immutability contract. User hashes are encoded in deterministic
  key order.

### Context and runtime services

- `Tamoz::Context` carries run, parent, execution, request, thread, namespace, and task
  identity plus tags, metadata, monotonic deadline, cancellation, clock, notifier, emitter,
  store, and effects.
- Identity fields are copied; tags, namespace, and metadata are deeply copied and frozen.
  Injected service handles are retained and are never frozen by Context.
- `#with` returns a validated copy. `#child` creates a new run id, links `parent_run_id`,
  appends one namespace component, and shares cooperative services.
- `#check!` raises `CancelledError` for token cancellation and `TimeoutError` for an expired
  monotonic deadline.
- `Tamoz::CancellationToken` is thread-safe, supports idempotent cancellation, waiting, and
  a bounded number of removable cancellation subscriptions. It never kills a Ruby thread.
- `Tamoz.instrument` delegates only to a notifier implementing `instrument`. Its guarded
  wrapper executes the application block at most once, returns the block's own value
  regardless of the notifier's return value, preserves an application exception and
  backtrace, and contains ordinary notifier failures. The no-notifier path is equivalent.
- Context inspection reports identity and metadata keys, never metadata values.
- Process configuration is replaced atomically with a frozen validated value. Finalization
  prevents later mutation.

### Execution-output streaming

- `Tamoz::StreamPart` validates event type, identity, non-negative sequence, finite
  monotonic emission time, namespace, and deeply immutable data. Its default inspection
  never displays payload content.
- `Tamoz::StreamSink` owns a `SizedQueue` with positive fixed capacity and at most one
  consumer. `#emit` blocks for backpressure, allocates sequence per namespace, and rejects
  emission after finish, closure, or cancellation. Its retained namespace sequence map has
  an explicit capacity.
- `#finish` is a normal producer completion and does not cancel. Early consumer exit or
  explicit `#close` cancels the shared token and closes the queue in `ensure`.
- Cancellation closes the queue and wakes blocked producers. Natural completion drains
  already accepted parts. Stream enablement or early closure cannot alter committed state;
  state commits remain an M2 responsibility.

### Ordered execution

- `Tamoz::Pool.for(:inline, ...)` and `Tamoz::Pool.for(:threads, ...)` expose one ordered
  `#map` contract. `:fibers` fails as unsupported until its conformance suite exists.
- Inputs are bounded by `max_tasks`; thread workers and the submitted-work queue are bounded.
- Results are returned in submission order as `TaskResult::Succeeded`, `Failed`,
  `Interrupted`, `Cancelled`, or `Stuck`.
- Worker-local `catch(:tamoz_interrupt)` distinguishes normal values from thrown interrupt
  descriptors without relying on exceptions.
- Cooperative cancellation stops new work, wakes queue waiters, rejects late success, and
  joins owned workers for a bounded grace period. The implementation never calls
  `Thread#kill`, `Thread#raise`, or `Timeout.timeout`.
- An uncooperative worker is reported as stuck and retired from the pool. Ruby cannot reclaim
  its thread safely; it may remain until user code returns. Reaching the configured stuck
  threshold opens the pool circuit for later calls, eventual late results are ignored, and
  operators are told that process restart is the hard containment boundary.
- Fatal exceptions are transferred back to the caller with their original exception and
  backtrace. Ordinary task errors remain typed failed results for the M2 coordinator.

## Implementation slices

1. Errors, immutable-copy helpers, Secret, StateCodec, and codec registrations.
2. Clock, cancellation token/subscription, Context, configuration, and notifier dispatch.
3. StreamPart and StreamSink.
4. TaskResult, InlinePool, ThreadPool, and pool factory.
5. Public API inventory, gem documentation, M1 conformance cases, clean-revision evidence
   recorder, and complete tests.
6. Deep review, corrections, reproducibility run, package install smoke, and M1 commit.
7. Run the evidence recorder against the clean M1 commit. If it fails, fix and recommit
   before closing M1.

Each slice must pass its focused tests before the next slice starts. M1 is committed only
after the combined gate and review pass.

## Acceptance evidence

- state-codec round trips, deterministic bytes, registration/version behavior, immutability,
  preflight-before-decoder, and rejection corpus;
- Secret rejection and redacted inspection;
- Context isolation across mutation attempts, child lineage, deadline, cancellation, and
  absence of thread/fiber-local tenant state;
- instrumentation equivalence with and without a notifier;
- randomized inline/thread result-order equivalence;
- interrupt capture inside each worker;
- work-queue capacity, cancellation, cooperative join, stuck result, circuit, and no
  asynchronous thread termination;
- stream capacity, ordered per-namespace sequence, blocked-producer wakeup, early-close
  cancellation, natural drain, single-consumer rule, and no retained cooperative workers;
- deterministic public M1 evaluation cases for codec safety, Context isolation, pool
  ordering, and bounded stream shutdown;
- a fixed, non-case-controlled recorder that runs those cases against a clean revision in an
  OS-enforced network sandbox and emits digest-verified result/evidence artifacts; cases
  never supply shell commands; unsupported hosts report the missing sandbox instead of
  overstating isolation;
- clean-process dependency isolation and installed-gem execution;
- public API inventory and documentation links;
- the full M0 gate remains green.

Local verification uses Ruby 3.3.11. The declared CI matrix covers Ruby 3.3, 3.4, and 4.0;
hosted results remain unproven until the commits are pushed.

## Plan review

Implementation may begin only if every answer is yes:

- Does the plan implement only ownership assigned to `tamoz-core`?
- Are persistence and graph semantics absent?
- Does every mutable runtime service have explicit ownership and bounded lifecycle?
- Does every durable input fail before partial user-code revival?
- Are secrets rejected rather than heuristically scrubbed?
- Can removing instrumentation leave execution results unchanged?
- Can cancellation complete without asynchronous thread termination?
- Are queues, workers, tasks, bytes, depth, and collections bounded?
- Are inline and threaded result order semantically equivalent?
- Does the evidence exercise package-installed behavior, not only repository load paths?
- Are M1 claims represented by executable evaluation cases rather than prose alone?

If a review answer becomes no during implementation, stop that slice and revise this plan
before continuing.

## Review result

Accepted for implementation on 2026-07-30.

| Question | Answer | Evidence or constraint |
|---|---|---|
| Core ownership only? | yes | Every public type maps to `CORE_DESIGN.md` §§1–7; graph state and orchestration remain absent. |
| Persistence and graph semantics absent? | yes | The codec owns value encoding only; it has no checkpoint, reducer, task-id, or resume behavior. |
| Mutable services owned and bounded? | yes | Tokens, sinks, pools, and configuration have explicit owners, close/finalize operations, bounded subscriptions and namespace history, capacities, and limits. |
| Fail before partial unsafe revival? | yes | Wire structure and every registration tag/version are preflighted before adapter decoders run. |
| Secrets structural? | yes | `Secret` is rejected from codec, stream, Context metadata, and instrumentation payloads; no key-name regex exists. |
| Instrumentation observational? | yes | The guarded block is at-most-once, its value/error wins, and ordinary notifier failures are contained. |
| Safe cancellation? | yes | Cooperative tokens, queue closure, grace joins, stuck reporting, and circuit opening replace asynchronous termination. |
| Resource limits complete? | yes | Bytes, depth, strings, collections, callbacks, tasks, workers, work queue, stream queue and namespace history, grace, and stuck count are bounded. |
| Inline/thread order equivalent? | yes | Both return typed results indexed and assembled by submission order; completion timing is excluded. |
| Installed behavior tested? | yes | The acceptance suite installs `tamoz-core` into an isolated GEM_HOME and runs codec/Context/pool/stream smoke. |
| Executable evaluation evidence? | yes | Four public cases map to fixed runner selections; a clean-revision recorder emits verified manifests after commit. |

Residual risk: uncooperative Ruby code can retain a retired thread until it returns. M1
reports and contains this condition but cannot reclaim that thread without violating the
explicit prohibition on asynchronous termination. Hard cancellation belongs in a supervised
subprocess adapter, not this pool.

## Closure

The deep review in [`reviews/M1_DEEP_REVIEW.md`](reviews/M1_DEEP_REVIEW.md) resolved all
phase-blocking findings. The final local gate passed 101 tests and 1,113 assertions with no
failures, errors, or skips, validated 22 design documents with 55 invariants and 40 ADRs,
and built all five gems. Clean-revision evidence is recorded after the M1 commit, as required
by implementation slice 7.
