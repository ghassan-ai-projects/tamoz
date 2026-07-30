# M2 deep review

Review target: uncommitted M2 implementation on top of `da0f8f5`

Date: 2026-07-30

Outcome: accepted after corrections. No known critical or high-severity finding remains
open. M2 remains explicitly in-memory and must not be described as crash durable.

## Method

The review traced `M2_PLAN.md`, graph invariants 1–15 and 52, and the public API through:

- definition compilation, canonical identity, state reduction, routing, task planning,
  barrier commit, interrupt/retry, history/fork, subgraph, and stream paths;
- mutation, stale-result, cancellation, stuck-worker, key-collision, anonymous-class,
  declaration-order, and consumer-close adversarial cases;
- an independent barrier reference model, 120 varied completion schedules, and generated
  cycles;
- hard/configured resource bounds and algorithmic complexity;
- safe failure/checkpoint/stream representations and secret-bearing message boundaries;
- dependency isolation, reproducible fixtures, installed-gem execution, and OS-denied
  network conformance records;
- strict syntax, design validation, the complete M0–M2 test gate, and diff hygiene.

## Resolved findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| critical | Equivalent graph digests could expose different channel and branch declaration order to user code. | The digest sorted declarations but the runtime retained insertion-ordered hashes. | Canonicalize channels, nodes, edges, and branches in `Definition`; verify identical observed state and checkpoint ids. |
| critical | Interrupt task/index identity did not fully participate in checkpoint ids. | Generic `#descriptor` detection confused the `Interrupt#descriptor` payload field with a complete persistence descriptor. | Encode internal checkpoint types explicitly and include interrupt task id, call index, and payload. |
| critical | A new pool policy object was created per barrier, discarding the stuck-worker circuit. | Pool ownership was treated as an execution detail rather than compiled runtime policy. | Bind reusable inline/thread pool policies to the compiled graph; inherited child bindings reuse their child pool policy. |
| high | Checkpoint metadata and state bytes were shallowly immutable. | `Data` froze the record but not caller-owned nested collections. | The memory checkpointer defensively copies/freezes strings, arrays, and hashes and rejects mutable opaque attributes. |
| high | Explicit `Send` keys could collide with positional keys and produce one task path. | Duplicate checks covered only explicit-to-explicit keys. | Validate every effective key before frontier construction. |
| high | Repeated subgraph calls in one parent activation reused completed child state. | Namespace identity omitted the positional child-call index. | Add a restart-stable call cursor to child namespace and execution identity. |
| high | Child schemas rejected parent-only input and leaked managed channels into parent updates. | Parent and child state were treated as identical schemas. | Project input to child channels and output to non-managed child channels. |
| high | In-memory checkpoint history was append-only but unbounded. | Only history read size and namespace count were bounded. | Add configured/hard checkpoints-per-namespace retention ceilings and test both retained dimensions. |
| high | Invalid execution identity or concurrency could create an input checkpoint before failing. | Context and runtime-policy validation happened after append. | Prepare/validate invocation context, input, frontier, booleans, and concurrency before mutation; normalize execution ids at every append. |
| medium | Anonymous exception classes could add object identity to failure checkpoints. | `Class#to_s` was used when `Class#name` was absent. | Persist the stable `AnonymousError` label and prove inline/thread failed ids match. |
| medium | Stream setup could retain a cancellation subscription; requesting `result` before consuming could deadlock on backpressure. | Sink ownership began before all setup validation, and result did not drain its queue. | Validate modes first, finish sinks on setup failure, implement one-consumer `Enumerable`, and drain on direct result requests. |
| medium | Compiler reachability was quadratic and definition collections lacked hard ceilings. | Repeated full edge scans and array membership were sufficient only for small fixtures. | Use indexed adjacency/reverse reachability and enforce hard structural bounds at declaration boundaries. |
| medium | The shipped graph gem directly required Zeitwerk without declaring it and still described unimplemented durability/effects. | M0 package text had not been revised for M2. | Declare the direct dependency, correct the guarantee boundary, inventory the public API, and execute the installed gem without repository load paths. |

## Five Whys: discarded stuck-worker circuit

1. Why could repeated runs start more work after a graph worker became stuck? Each barrier
   created a new `Pool::Threads`.
2. Why did a new pool matter if worker threads themselves were per-map? The circuit and
   cumulative stuck count belong to the pool policy object.
3. Why was that object short-lived? The executor selected concurrency and constructed all
   policy locally.
4. Why was ownership placed there? Pool construction had been viewed as mechanics, while its
   safety state was overlooked.
5. Why did focused success tests miss it? They proved one cancellation lifecycle, not a
   second run against the same compiled graph.

The fix moves policy ownership to `Compiled`, where runtime configuration is bound and
shared across barriers and runs. The adversarial test fills every worker, cancels, waits for
stuck classification, and proves a later run is rejected before user code.

## Verified boundaries

- One successful barrier derives from one frozen base and one ordered outcome batch.
- Pause and failure append unchanged state; retained successful siblings are bounded and
  reused by logical activation id.
- Activation identity survives retry; attempt identity changes with attempt number and base.
- Checkpoint order comes only from backend integer sequence; opaque ids are never ordering.
- Branches observe the normalized candidate, and every dynamic route is declared and
  validated before commit.
- Invocation-mode children share the parent memory checkpointer under deterministic,
  positional namespaces.
- Streaming is observational: event projection has no branch in planning, reduction, or
  checkpoint identity.
- `tamoz-graph` loads no eval, persistence, agent, model/provider, HTTP, or socket package.

## Residual boundaries

- Cooperative cancellation cannot terminate arbitrary Ruby code. A stuck worker may remain
  alive until user code returns; its late value is fenced out, and the retained pool circuit
  prevents repeated scheduling. Hard termination requires a supervised process adapter.
- `MemoryCheckpointer` is process-local. Its strict sequence, fork, and compare-and-append
  model is semantic evidence, not recovery evidence.
- M2 has no lease, request inbox, effect journal, or multi-process owner. Those guarantees
  remain blocked on M3 and its crash/fault conformance suite.
- Custom reducer and node identity is declared by the application. M2 makes that identity
  explicit but cannot prove arbitrary user callables are pure.

## Gate

Commit is allowed only after the final `bundle exec rake ci` is green, all six M2 records
verify under OS-enforced network denial, `git diff --check` is clean, and the exact committed
revision passes the clean-revision recorder.
