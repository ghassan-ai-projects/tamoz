# `tamoz-core` — shared runtime values

`tamoz-core` has no orchestration, persistence, provider, or network behavior. It owns the
small values and protocols that must cross package boundaries.

Runtime dependencies: Ruby standard library and Zeitwerk only.

## 1. Value boundary

Tamoz does not define a provider-facing message hierarchy. `tamoz-agent` consumes
`RubyLLM::Message`, `RubyLLM::Tool`, `RubyLLM::Chat`, and `RubyLLM::Agent` through their
public APIs.

The graph runtime accepts only values its configured codec can persist and isolate:

- nil, booleans, finite numbers, UTF-8 strings;
- arrays and hashes with schema-declared string/symbol keys;
- registered immutable Tamoz values;
- registered adapter values with a versioned codec.

`Data.define` being shallowly frozen is not sufficient. At checkpoint commit, the runtime
normalizes supported values, copies mutable containers, and recursively freezes the
committed snapshot. Unsupported values fail before a node can observe them. A graph compiled
without persistence may opt into opaque values, but then it is explicitly ephemeral and
cannot claim replay or crash safety.

The RubyLLM adapter is responsible for a lossless, versioned message codec. Fixtures cover
tool-call ids, content blocks, citations, attachments, reasoning metadata, and unknown
provider fields. Avoiding wrapper objects does not remove the need for a durable wire
format.

## 2. `Tamoz::Context`

`Context` is the explicit capability set for one call:

```ruby
# Illustrative
Tamoz::Context = Data.define(
  :run_id,
  :parent_run_id,
  :execution_id,
  :request_id,
  :thread_id,
  :namespace,
  :task_id,
  :tags,
  :metadata,
  :deadline,
  :cancellation,
  :notifier,
  :emitter,
  :store,
  :effects
) do
  def with(**changes) = ...
  def child(name, task_id: nil) = ...
  def emit(type, data = {}) = emitter.emit(type, namespace, data)
  def expired? = deadline && monotonic_now >= deadline
  def cancelled? = cancellation&.cancelled?
  def check! = raise Tamoz::CancelledError if cancelled? || expired?
end
```

Rules:

1. It is always the second positional argument: `step.call(input, context)`.
2. `#child` is called at every step, node, subgraph, tool, and model boundary.
3. Tenant/run state is never stored in `Thread.current`, fiber locals, or mutable globals.
4. Runtime behavior is supplied through typed compile/invoke arguments. There is no
   free-form `configurable` dispatch bag.
5. `metadata`, tags, and namespace are copied and deeply frozen. Injected services are
   immutable handles; Context never freezes third-party service objects.
6. Store access is already tenant-scoped by the session boundary.
7. Effect calls require the current `task_id`; code outside a task cannot invent durable
   effect identity.

`run_id` is a trace span for one live invocation and changes on resume. `execution_id` is
durable workflow identity and remains stable across resume. `request_id` deduplicates the
external input that started or resumed it.

Deadlines use monotonic time and are runtime-only. Cancellation is cooperative: Tamoz stops
scheduling, signals owned workers, and ignores late state results, but cannot promise that a
remote system or arbitrary Ruby method stops immediately.

## 3. Streaming

```ruby
# Illustrative
Tamoz::StreamPart = Data.define(
  :type, :namespace, :run_id, :task_id, :sequence, :data, :emitted_at
)
```

`sequence` is monotonic within one producer namespace. Global live-event order across
parallel tasks is intentionally unspecified. Consumers order by namespace/sequence when
needed; committed state order comes from task paths, not event timing.

Core event types:

| Type | Data, redacted by default |
|---|---|
| `:run_start` / `:run_end` | graph, run id, status, duration |
| `:task_start` / `:task_end` | node, task id, attempt, duration |
| `:node_update` | node, changed key names; values require content capture |
| `:message_chunk` | content only when the surface explicitly requests it |
| `:tool_start` / `:tool_progress` / `:tool_end` | tool, effect key, status; args/results protected |
| `:interrupt` | interrupt id and kind; payload protected |
| `:checkpoint` | id, sequence, source, fence |
| `:effect_unknown` | effect key, operation, reconciliation instructions |
| `:error` | class, category, retryable, safe user message |
| `:custom` | schema and sensitivity supplied by user code |

The public stream is a lazy `Enumerator`. Under parallel execution a `Tamoz::StreamSink`
bridges workers through a small `SizedQueue`:

- capacity is bounded and configurable;
- enqueue applies backpressure;
- closing the consumer cancels the run and closes the sink in `ensure`;
- the coordinator joins cooperative workers it owns;
- late emissions after closure are rejected, not buffered;
- a surface that wants lossy telemetry uses instrumentation, not the stream.

Streaming is a projection of the single execution path. Enabling, filtering, or stopping a
stream cannot change bytes already committed to a checkpoint.

## 4. Instrumentation

Instrumentation is observer-only:

```ruby
# Illustrative
def instrument(name, payload, context:)
  notifier = context.notifier
  return yield(payload) if block_given? && !notifier.respond_to?(:instrument)
  return unless notifier.respond_to?(:instrument)

  block_given? ? notifier.instrument(name, payload) { yield(payload) } :
                 notifier.instrument(name, payload)
end
```

Event names are versioned: `tamoz.run.v1`, `tamoz.task.v1`, `tamoz.checkpoint.v1`,
`tamoz.effect.v1`, `tamoz.interrupt.v1`. Payload schemas distinguish low-cardinality metrics
from trace attributes. User ids, thread ids, task ids, and effect keys are trace attributes,
not metric labels.

Prompts, chunks, tool arguments/results, filesystem paths, and exception messages are
excluded by default. An explicit content-capture policy controls them consistently across
streams, logs, traces, and `inspect`.

If removing the notifier changes behavior, the feature belongs in the stream or state.

## 5. Errors

```text
StandardError
├── Tamoz::Error                         operational
│   ├── TimeoutError
│   ├── CancelledError
│   ├── NodeError
│   ├── CheckpointError
│   │   ├── CheckpointConflictError
│   │   ├── CheckpointVersionError
│   │   └── CheckpointCorruptionError
│   ├── LeaseLostError
│   ├── EffectUnknownError
│   └── StoreError
├── Tamoz::ConfigurationError            programmer error
├── Tamoz::GraphDefinitionError          programmer error
├── Tamoz::InvalidUpdateError            programmer/dataflow error
└── Tamoz::RecursionLimitError            graph policy exhaustion
```

An interrupt is not an exception. Worker-local `catch(:tamoz_interrupt)` turns it into a
typed `TaskResult::Interrupted`.

Tool errors are classified:

- recoverable/model-actionable: invalid arguments, user denial, a confirmed pre-dispatch or
  successfully cancelled timeout, and expected external failures become typed tool-result
  values;
- operational but not model-actionable: lease loss, cancellation, storage failure,
  corruption, auth configuration, and effect ambiguity pause or fail the run;
- programmer errors: bugs and contract violations propagate with the original backtrace.

No broad rescue may turn every exception into model text. That would hide policy failures,
corruption, and code defects.

Errors expose stable `category`, `retryable?`, `user_visible?`, and `safe_message`; raw
exception text is protected by the content-capture policy.

## 6. Concurrency

```ruby
# Illustrative
results = Tamoz::Pool.for(:threads, size: 8).map(tasks) do |task|
  catch(:tamoz_interrupt) { execute(task) }
end
```

The real worker wrapper distinguishes a normal value from the return value of `catch` with
an internal sentinel and returns a typed `TaskResult`.

Modes:

| Mode | Use |
|---|---|
| `:inline` | deterministic debugging and most unit tests |
| `:threads` | production default for bounded I/O concurrency |
| `:fibers` | optional `async` integration after its conformance suite passes |

The pool:

- submits in task-path order and returns results in that order;
- never kills Ruby threads asynchronously;
- propagates cooperative cancellation;
- captures interrupts inside the worker stack;
- bounds queue length and worker count;
- joins cooperative workers and closes owned resources in `ensure`.

Ruby cannot safely terminate arbitrary code in a thread. After a cancellation grace period,
an uncooperative task is marked `:stuck`, its worker is retired, and its eventual state
result is rejected by cancellation/fencing. Tamoz never uses `Thread#kill`. A bounded stuck
worker threshold opens a circuit and asks the operator to restart the process. Tools that
need hard cancellation run in a supervised subprocess whose process group can be
terminated and reaped.

Timeout decorators set a deadline and cancellation token. They do not use `Timeout.timeout`
around arbitrary user code and do not imply an external side effect was rolled back. If
completion is ambiguous, the effect journal decides `:unknown`; the timeout is not returned
as an ordinary tool error.

## 7. Configuration

Global configuration contains process-wide defaults only:

```ruby
Tamoz.configure do |config|
  config.concurrency = :threads
  config.pool_size = 8
  config.recursion_limit = 200
  config.stream_buffer = 32
  config.notifier = MyNotifier
end
```

Checkpointers, stores, credential providers, policies, and tenant metadata are constructed
and injected at compile/session boundaries. Configuration freezes after boot in production.

`inspect` redaction by field name is defense in depth, not the secret boundary. Sensitive
values use explicit wrappers and policies as defined in
[PERSISTENCE_DESIGN.md](PERSISTENCE_DESIGN.md).
