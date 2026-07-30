# M2 implementation plan — deterministic in-memory graph

Status: implemented and deep-reviewed; commit and clean-revision evidence remain.

M2 implements the deterministic execution algebra in `tamoz-graph`. It uses an append-only
in-memory checkpointer to prove planning, barrier, identity, interrupt, history, fork, and
streaming semantics. It does not claim crash durability, lease fencing, external-effect
safety, request deduplication, or multi-process coordination; those are M3 responsibilities.

## Outcome

M2 produces an LLM-independent compiled graph that:

- validates and digests explicit state, node, edge, branch, reducer, default, and limit
  declarations;
- executes Bulk Synchronous Parallel super-steps over one immutable snapshot;
- commits one reducer-mediated candidate state per successful barrier;
- gives inline and threaded execution byte-identical committed histories;
- supports typed dynamic routing, keyed fan-out, worker-local interrupts, restart-from-top,
  positional resume, failure retry, history, and reducer-mediated forks;
- projects one execution through the bounded M1 stream without changing state behavior.

## Public contract

### Definition

```ruby
graph = Tamoz.graph(name: "review", version: "1") do
  state :findings, reduce: :union, default: []
  state :status
  state :remaining_steps, managed: Tamoz::Managed::RemainingSteps

  node :plan, Plan
  node :analyse, Analyse, routing: :additive, routes: [Tamoz::END, :review]
  node :review, Review

  edge Tamoz::START, :plan
  edge :plan, :analyse
  branch :analyse, version: "1", targets: [Tamoz::END, :review] do |state|
    state[:findings].empty? ? Tamoz::END : :review
  end
  edge :review, Tamoz::END
end

app = graph.compile
```

- Graph, node, channel, and route names are copied, bounded UTF-8 identifiers without
  controls. `START` and `END` are typed virtual markers, not user-definable nodes.
- Top-level channel keys are symbols in node snapshots. Input and updates may use the
  declared symbol or its string form; ambiguous duplicates fail.
- A channel is last-value, reducer-backed, or managed. Last-value accepts zero or one write
  per barrier. Reducers receive `(current, ordered_writes)` exactly once. Topic-channel
  consumption is deferred until its scheduler contract is separately specified; M2 PUSH
  tasks come from explicit `Send` values.
- Built-ins are `:append`, `:merge`, `:union`, `:max`, and `:min`. A custom reducer requires
  a stable name and version. A callable default requires a stable name and version.
- Custom reducers use `reducer_name:` and `reducer_version:`; callable defaults use
  `default_name:` and `default_version:`. Omitted or unstable identities fail compilation.
- A named class/module/callable is invoked through `#call(state, context)`. Anonymous node
  behavior requires an explicit stable name and version. Graph version changes remain the
  application's compatibility responsibility.
- Callable defaults are evaluated twice during compilation, normalized through the codec,
  and required to produce identical bytes. The compiled graph retains the canonical
  prototype and copies it per input checkpoint; factories do not run during execution.
- A raw branch block must declare every possible target. Returned targets are validated
  again at runtime. This makes compile-time reachability and definition digests honest.
- `routes: [...]` declares every possible `Command#goto` target. `routing: :dynamic` is
  required for dynamic-only nodes; `routing: :additive` is required when static/branch and
  dynamic successors coexist. Returning an undeclared route or returning any dynamic route
  from `routing: :static` fails before commit.
- Compilation rejects unknown/unreachable targets, duplicate declarations, missing entry or
  terminal paths, unsupported reducers/managed values, and invalid defaults.
- Structural declarations are canonicalized into a domain-separated SHA-256
  `definition_digest`. Hash order, object ids, source paths, and completion timing cannot
  change it.

### Values

- `Tamoz::Command` contains immutable `update`, `goto`, `resume`, and `graph` fields.
- `Tamoz::Send` contains a target node, immutable input, and optional stable key.
- `Tamoz.send_to` is the constructor helper.
- `Tamoz.interrupt(descriptor, context)` delegates to an explicit task-local interrupt
  cursor in Context. It never uses thread/fiber locals or an exception.
- `Tamoz::Graph::Checkpoint`, `Snapshot`, `Interrupt`, `Task`, and `RunResult` are immutable
  inspection values. Internal pending writes and scheduler state are not writable public
  collections.
- User state and resume values obey `StateCodec`; arbitrary symbol values are rejected.
  Symbols remain DSL/routing identifiers only. Approval examples therefore use
  `"approve"`, not `:approve`.

### Invocation and history

```ruby
result = app.invoke(
  {"status" => "new"},
  thread: "thread.1",
  request_id: "request.1",
  execution_id: "execution.1",
  concurrency: :threads
)

resumed = app.resume(
  {interrupt.task_id => {interrupt.call_index => "approve"}},
  thread: "thread.1",
  request_id: "request.2"
)

retried = app.retry_failed(thread: "thread.1", request_id: "request.3")
continued = app.continue(thread: "thread.1", request_id: "request.4")

snapshot = app.state(thread: "thread.1")
history = app.history(thread: "thread.1")
forked = app.update_state(
  {findings: ["manual"]},
  thread: "thread.1",
  checkpoint_id: older.id
)
```

- `invoke` creates a new execution and input checkpoint. Reusing a non-empty thread requires
  explicit `new_execution: true`; M2 does not pretend to deduplicate `request_id`.
- Checkpoint sequences are backend-assigned strictly increasing integers per thread and
  namespace. Checkpoint ids are opaque domain-separated digests and are never ordering.
- Every checkpoint pins graph name, version, definition digest, execution id, parent id,
  immutable state, next frontier, pending successful outcomes, interrupts, and cumulative
  resume values.
- Pending outcomes are normalized into bounded internal records containing only task
  identity, immutable update values, and canonical route descriptors. A failure checkpoint
  stores bounded safe failure metadata; the immediate `RunResult` retains the original
  `NodeError` and cause for debugging.
- `state` returns the selected immutable checkpoint projection. `history` is newest-first,
  bounded by a required/default limit, and never exposes mutable storage.
- `update_state` uses the same barrier code. Editing a historical checkpoint appends a fork
  with a new execution id and never mutates or consumes the source execution.
- M2's memory checkpointer is process-local. Its history proves append/sequence/fork algebra,
  not recovery after process loss.

## Planning and identity

Planning is a pure function of the compiled definition and selected checkpoint.

- PULL successors are de-duplicated by target per barrier. Fan-in therefore activates once.
- PUSH tasks come only from `Send`; order and path derive from declared array position and
  stable key, never completion timing.
- A frontier entry stores node, kind, path, input, activation checkpoint, and logical step.
- Logical activation id is a domain-separated digest of definition digest, execution id,
  activation checkpoint id, logical step, kind, and full path.
- Attempt id is a separate digest of activation id, attempt number, and current base
  checkpoint id.
- Task results include both identities and the base id. The barrier rejects any mismatch
  before using its value.
- Results and writes sort by full task path. No UUID, wall clock, Hash insertion, or worker
  completion order affects a committed checkpoint.

## Execute, pause, failure, and barrier

1. Plan all frontier tasks from one frozen checkpoint.
2. Reuse pending successful outcomes by logical activation id.
3. Execute remaining tasks with the M1 ordered pool and explicit child Context.
4. Convert node returns into immutable outcomes:
   `nil`, update Hash, or `Command(update:, goto:)`.
5. If any task interrupts, append a pause checkpoint with unchanged state, all interrupt
   descriptors, and successful sibling outcomes. Do not run reducers.
6. If any task fails, append a failed checkpoint with unchanged state, the original
   `NodeError`, and successful sibling outcomes. Explicit retry reuses siblings.
7. If cancellation, stuck work, or a limit occurs, commit no candidate state.
8. Otherwise validate every attempt/base identity, sort outcomes, group writes, call every
   affected reducer once, normalize the whole candidate, compute routes from the candidate,
   and append exactly one next checkpoint.

Parallel writes to a last-value channel raise one `InvalidUpdateError` naming every logical
task id before state commit. An unknown/read-only channel, invalid node return, invalid
route, reducer failure, or unsupported candidate value also commits no candidate state.

## Interrupt and resume

- The worker-local cursor increments `call_index` for each interrupt call.
- A stored resume value for `(task_id, call_index)` is returned. Otherwise an immutable
  interrupt descriptor is thrown through `:tamoz_interrupt` and caught by the same pool
  worker.
- On resume, interrupted nodes restart at line one. Previously supplied indices replay;
  the first unanswered index pauses again.
- Parallel answers are keyed by logical task id and call index. Unknown task/index,
  duplicate, or malformed answers fail before user code.
- The existing pause checkpoint is the resumed attempt's new base. Resume preserves
  execution and activation ids, increments attempt number, and changes attempt/base
  identity; the next pause or successful barrier appends the next checkpoint.
- Already successful siblings are never invoked again. A forged stale attempt cannot enter
  the barrier.

## Routing

- Static edges and branch outputs create PULL targets for the next barrier.
- `Command#goto` with node markers creates PULL targets.
- `Command#goto` with `Send` values creates ordered PUSH targets. Missing keys derive from
  their array position; duplicate explicit keys for one task fail.
- Declared and dynamic successors are additive only when the source node opted into
  `routing: :additive`.
- `END` creates no task. The run completes when the next frontier is empty.
- Branches observe the fully normalized candidate state, not a partially applied task
  result.

## Subgraphs

M2 supports invocation-mode compiled subgraphs as nodes:

- the parent executor injects its one memory checkpointer explicitly;
- the child uses a deterministic namespace extending the parent task path;
- a positional child-call index makes repeated calls in one parent activation fresh while
  preserving the same namespace after parent restart;
- no child creates or selects a backend during execution;
- child checkpoints remain independently inspectable by namespace;
- parent input is projected to child channels; a completed child returns its non-managed
  final channels as the parent node update;
- interrupts bubble as a parent task interrupt and restart the child through its recorded
  boundary.

Thread-persistent and stateless subgraph modes remain unavailable until their separate
semantics and conformance cases exist.

## Streaming and limits

- `stream` runs the same `invoke` path with a bounded `StreamSink`.
- Modes select event projections only. They cannot alter planning or barrier inputs.
- Early enumerator closure cancels the run, closes the sink, wakes blocked producers, joins
  owned coordinator/workers for the configured grace, and never commits late state.
- `run_start`, task, node update, interrupt, checkpoint, error, and `run_end` events carry
  explicit graph/run/task identity with redacted payload inspection.
- Independent hard/configured bounds cover steps, tasks per step, total tasks, state bytes,
  pending outcome bytes, history reads, stream capacity, namespace cardinality, and
  cancellation subscriptions.

Static before/after breakpoints and topic channels remain unavailable in M2. They are not
silently approximated with worker interrupts.

## Acceptance evidence

- graph compiler rejection corpus and definition-digest fixtures;
- reducer laws plus whole-batch invocation and last-value conflict tests;
- independent reference-model properties over linear, branch, cycle, fan-out/fan-in shapes;
- 100+ randomized completion schedules proving inline/thread histories byte-identical;
- golden activation/attempt/checkpoint identity fixtures;
- three sequential interrupts inside `rescue StandardError`, in inline and threads;
- parallel interruption, positional resume validation, restart-from-top, sibling reuse,
  failure retry, and forged stale-result rejection;
- reducer-mediated historical fork and strict sequence tests;
- additive routing, PULL fan-in, keyed PUSH fan-out, branch-candidate visibility, and routing
  rejection tests;
- nested parallel subgraphs proving one checkpointer and deterministic namespaces;
- stop streaming at every event index; compare last committed state with non-streamed runs
  and assert no retained cooperative threads;
- clean-process dependency isolation and installed-gem execution;
- public M2 evaluation cases and a fixed clean-revision evidence recorder;
- the complete M0+M1 gate remains green.

## Plan review

Implementation may begin only if every answer is yes:

- Is every M2 claim explicitly in-memory, with no implied M3 crash/effect/lease guarantee?
- Can every committed value be derived from one frozen base plus an ordered whole batch?
- Are logical activation, attempt, checkpoint, execution, path, and sequence identities
  distinct and deterministic?
- Can pause/failure retain siblings without committing partial state or rerunning them?
- Does resume restart user code and match values by exact task and call index?
- Are all dynamic routes declared/validated without executing branch code at compile time?
- Can subgraphs inherit one backend without ambient state?
- Can streaming be removed without changing committed checkpoint bytes?
- Are every queue, collection, history read, task count, and serialized value bounded?
- Do tests include an independent reference model and adversarial schedule variation?
- Does implementation avoid `tamoz-evals`, RubyLLM, providers, HTTP, and persistence adapters?

If any answer becomes no, revise this plan before continuing.

## Review result

Accepted for implementation on 2026-07-30 after the corrections below.

| Question | Answer | Evidence or constraint |
|---|---|---|
| M2 claims only in-memory guarantees? | yes | Checkpoints model append/sequence/fork semantics, while crash recovery, leases, effects, request inboxes, and multi-process ownership are explicitly excluded until M3. |
| One frozen base and one whole batch? | yes | Workers return normalized outcomes only; pause/failure leaves state unchanged; the barrier groups every successful write before one candidate normalization and append. |
| Identities distinct and deterministic? | yes | Activation, attempt, checkpoint, execution, path, and backend sequence have separate recipes and tests; none use time, UUID order, completion timing, or object identity. |
| Sibling reuse atomic? | yes | Pause/failure checkpoints persist bounded canonical outcomes, never reducer output; retry consumes them only when every activation completes. |
| Resume exact and restart-from-top? | yes | The pause checkpoint becomes the new base, cursors replay cumulative `(task_id, call_index)` answers, and user code is invoked again from its entry. |
| Dynamic routes honest? | yes | Branch and `Command#goto` target sets are mandatory metadata, raw routing code never runs during compile, and every actual target is checked before commit. |
| Subgraphs avoid ambient ownership? | yes | Only the parent executor can supply the checkpointer and namespace to an invocation-mode child; Context remains explicit. |
| Streaming observational? | yes | One coordinator path accepts either a null or bounded emitter; state, planning, reducer, and checkpoint code have no stream-mode branches. |
| Resources bounded? | yes | Plan limits state/pending bytes, steps, total/per-step tasks, history reads, stream buffers/namespaces, callbacks, pools, and joins. |
| Independent evidence? | yes | A separate reference model, identity goldens, adversarial schedules, early-close matrix, installed-gem smoke, and canonical evaluation cases are required. |
| Dependency boundary intact? | yes | Graph depends only on core and Zeitwerk; dependency isolation forbids evals, persistence, provider, model, HTTP, and socket loading. |

Corrections made during review:

- an earlier draft invented an extra resume checkpoint; the accepted contract correctly uses
  the persisted pause checkpoint as the next attempt base;
- arbitrary symbol resume/state values conflicted with the M1 durable codec, so symbols are
  restricted to trusted DSL/routing identities;
- raw exceptions and arbitrary node results were removed from checkpoint records in favor
  of bounded canonical pending/failure descriptors;
- topic channels and static breakpoints were removed from M2 rather than approximated
  without their full scheduler semantics;
- callable defaults are canonicalized at compile time and never re-executed during a run.
- `Command#goto` initially lacked compiler-visible target metadata; the accepted DSL now
  requires `routes:` and distinguishes `:static`, `:dynamic`, and `:additive` intent.

Post-implementation review additionally corrected:

- declaration-order behavior under a declaration-order-independent digest;
- shallowly mutable checkpoint metadata and unbounded retained in-memory history;
- an omitted interrupt task/index contribution to checkpoint identity;
- `Send` positional/explicit key path collisions;
- sequential subgraph calls reusing one invocation namespace;
- child managed-channel leakage and parent-only input rejection;
- per-barrier pool construction that discarded the stuck-worker circuit;
- anonymous exception class object identity entering failure checkpoints;
- invalid invocation configuration creating an input checkpoint;
- stream setup subscription leaks and result-before-consumption backpressure deadlock;
- quadratic graph reachability analysis and missing structural hard bounds.

Residual boundary: M2 can prove deterministic restart and sibling reuse only while its
in-memory checkpointer exists. M3 must run the same semantics across process termination,
lease transfer, and SQLite compare-and-append before Tamoz calls them durable.
