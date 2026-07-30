# Architecture review

Status: resolved in this revision
Date: 2026-07-30
Scope: `agentic-framework/design-v0.1/`

## Executive assessment

The original design had a strong center: a Ruby-native BSP graph runtime, explicit state,
checkpointed interrupts, small public contracts, and a demanding reference application.
It was clearer than a direct LangGraph port and correctly kept the scheduler independent of
an LLM.

It was not yet safe to implement. Several claims crossed subsystem boundaries that the
contracts did not cover. Most importantly, checkpointing alone cannot guarantee that an
external side effect will not run twice. The design also placed the `catch` for an interrupt
outside the worker thread that executes the `throw`, used a composition operator that loses
`Context`, allowed concurrent runners to append to one thread without fencing, and treated
UUID ordering and key-name secret scrubbing as stronger guarantees than they are.

This revision keeps the core thesis and changes the failure model. The result promises:

- deterministic, atomic state transitions at committed barriers;
- at-least-once task execution after an ambiguous crash;
- replay-safe effects when the target supports idempotency or atomic participation;
- an explicit `:unknown` state, never a blind retry, for non-idempotent effects;
- one fenced writer per `(thread_id, checkpoint_ns)`;
- resume only against a compatible graph definition and record format;
- bounded, cancellable streaming with deterministic final state;
- explicit sensitive-data policy instead of lossy serializer magic.

## Implementation-readiness correction

A second whole-design review found one blocking identity contradiction and six important
boundary gaps. This revision resolves them as contracts and conformance cases:

| Severity | Finding | Resolution |
|---|---|---|
| P0 | Task id included the mutable base checkpoint while interrupt resume expected the id to survive a new checkpoint | Stable logical activation id is now separate from attempt id; pending writes/effects use activation identity and barriers validate attempt/base |
| P1 | Request methods could deduplicate one id but did not define durable FIFO, redirect, join, or recovery semantics | Request ledger is now a sequenced durable inbox with explicit queue/redirect state transitions and schema |
| P1 | Thread deletion after lease expiry could erase the sink needed by a late remote-effect receipt | Two-phase tombstone/purge blocks unresolved effects and retains late receipt truth |
| P1 | Physical dispatch checked freshness but not Situation completeness, quorum, source health, calibration, gaps, or conflict | Typed intents declare evidence thresholds and R2/R3 policy fails closed before and after approval |
| P1 | Blocking every tool before the action plan encouraged plans made without evidence | A separately reviewed bounded read-only discovery plan gathers evidence but cannot authorize action |
| P1 | One 92–138-day first release delayed usable feedback and correlated memory, skills, healing, and improvement risk | Delivery is staged as v0.1 durable deliberation, v0.2 memory/skills, and v0.3 healing/improvement without removing their designed contracts |
| P2 | Optional SQLite feature ownership, stream hashing/partitioning versions, and repository shape were implicit | Structural versioned adapter protocols, digest/partition versions, and monorepo ADR-040 are explicit |

The remaining open choice is the first physical deployment profile and its independent
hazard model. It does not block the standalone v0.1 foundation.

## Root cause: five whys

1. **Why could a tool execute twice after `kill -9`?** The process can die after the tool's
   external effect succeeds and before its result is durably recorded.
2. **Why did the checkpointer not prevent that?** A local database transaction cannot
   atomically commit an unrelated filesystem, email, shell, or remote API effect.
3. **Why was there no effect protocol?** Nodes were modeled as pure state transforms, while
   side-effecting tools were added later as an agent-layer concern.
4. **Why did the test plan miss the gap?** Crash injection targeted super-step barriers, not
   the effect-success/receipt-commit seam.
5. **Why did traceability not expose it?** The matrix mapped features to primitive names,
   but did not map end-to-end guarantees to every failure boundary they cross.

The systemic fix is not another checkpointer method. It is an honest execution contract:
stable effect identities, a durable effect journal, target idempotency where available,
reconciliation where it is not, and fault injection at every persistence/effect seam.

## Findings and resolutions

| Severity | Finding | Evidence | Resolution |
|---|---|---|---|
| Critical | “No duplicated side effects” was impossible as stated | External effects and checkpoint commits do not share a transaction | Added the effect safety model and invariant 21; unsupported ambiguity pauses instead of retrying |
| Critical | `throw` was caught outside the executing worker | Ruby searches the current execution stack; a worker-thread `throw` otherwise raises `UncaughtThrowError` | Catch at the task boundary inside each worker and return an interrupt result to the coordinator |
| Critical | Two runners could advance one thread concurrently | No lease, compare-and-swap, or fencing token existed | Added durable leases and fenced commits as invariant 20 |
| Critical | `put` and pending-write handling were not an atomic state transition | Adapter transactions were optional and `get` did not return pending writes | Replaced them with `load`, idempotent `append_writes`, and atomic compare-and-append `commit` |
| High | A changed graph could resume old checkpoints silently | Checkpoints carried no graph identity or compatibility policy | Added graph name, version, definition digest, and explicit migrations |
| High | `Proc#>>` cannot preserve `#call(input, context)` | Native composition forwards the first result as one argument | `Tamoz.seq` is canonical; callables are adapted with `Tamoz.step`; native `Proc#>>` is not used |
| High | UUIDv7/ULID is not a strict per-thread sequence | Time-sortable identifiers do not define conflict-free append order | Added a backend-assigned integer `sequence`; ids remain opaque identity only |
| High | `:async` durability contradicted crash-safe defaults | Returning before commit permits acknowledged work to disappear | Durable graphs commit synchronously; buffered/ephemeral execution is named and opt-in |
| High | Automatic secret scrubbing could corrupt state and still miss secrets | Key-name regexes have false positives and false negatives | Serialization is allowlisted and lossless; sensitive values are rejected or explicitly protected |
| High | `Context` was referenced as an emitter/store carrier without those fields | `ctx.emit` and `context.store` appeared outside its declared shape | Added explicit emitter, store, and effect-journal capabilities |
| High | Model-facing tool results could vary with thread completion order | Parallel tools completed nondeterministically | Stream progress may be completion-ordered; committed messages are always tool-call ordered |
| High | Resume and fork shared deterministic identities | Pending writes/effect receipts from a source run could leak into intentional replay | Added `execution_id`: stable on resume, new on turns/forks; effect-bearing forks require policy |
| High | Late effect receipts were coupled to graph-lease ownership | An operation may finish after lease expiry; rejecting its receipt forces the new owner to guess | Graph fence authorizes start; a separate attempt token authorizes truthful completion only |
| High | Duplicate surface delivery had no durable claim | CLI retry, cron restart, or gateway redelivery could append two turns | Added request inbox with stable id, input digest, execution id, and terminal outcome |
| Medium | “One interface in the whole stack” was false | Serializer, notifier, store, checkpointer, and pool are separate contracts | Reworded as one execution protocol |
| Medium | Seven or more gems were described as “six” | Architecture, ADR, and roadmap disagreed | v0.1 now ships four runtime gems; deferred packages have promotion gates |
| Medium | Ruby 3.2 was already end-of-life | The design date is after Ruby 3.2 support ended | Floor moved to Ruby 3.3; CI targets 3.3, 3.4, and 4.0 |
| Medium | RubyLLM assumptions had drifted | RubyLLM now has a first-class `Agent` configuration API and evolving provider/model counts | Tamoz accepts RubyLLM agents/chats and avoids volatile numeric claims |
| Medium | Skill discovery contradicted prompt-prefix stability | Descriptions were in the prefix, yet adding a skill supposedly did not change the epoch | Skill catalogs are snapshotted per cache epoch |
| High | MCP/skills could smuggle authority through metadata | Remote annotations and `allowed-tools` come from content outside local policy | One source-qualified capability catalog intersects local/agent/task/parent grants; content can only narrow |
| High | “Cron is just another surface” omitted time and crash semantics | DST, misfire, overlap, duplicate scanners, delayed authority, and enqueue/execution status were undefined | `tamoz-scheduler` owns durable occurrences and delivers stable request ids; the agent lifecycle remains separate |
| High | Mutable skill paths made resume and supply chain irreproducible | A path/version can serve changed bytes or silently shadow another source | Canonical tree digests, explicit source binding, inert load, and staged/evaluated activation |
| Critical | “Streaming” meant output tokens, not an unbounded changing world | A finite agent run has no event-time, watermark, late-data, backpressure, keyed-state, or source-recovery semantics | `tamoz-stream` deterministically produces immutable Situations; only persisted admissions start bounded episodes |
| Critical | A model-to-actuator path would make stale inference a physical command | Approval alone cannot prove current device state, functional safety, or outcome | Typed intent is revalidated against current state and external interlocks before a narrow journaled effector; safety-critical control remains external |

## Scope decision

The reference agent does not consume `tamoz-chain`, Rails, ActiveRecord, MCP, or durable
scheduling in the first proof. Shipping them before the durable runtime is proven weakens
the design's own rule:
every primitive needs a real consumer.

v0.1 therefore contains four runtime gems:

1. `tamoz-core`
2. `tamoz-graph`
3. `tamoz-sqlite`
4. `tamoz-agent`

Tamoz Agent is the reference application, not a framework gem. `tamoz-chain`, `tamoz-rails`,
and `tamoz-activerecord` remain candidate extensions. `tamoz-stream`, `tamoz-mcp`, and
`tamoz-scheduler` now have accepted post-v0.1 contracts and promotion gates, but no v0.1
runtime dependency. `tamoz-stream` is the first product milestone after the durable base
because the physical-world agent is its demanding consumer.
Skills remain inside `tamoz-agent` and must satisfy their v0.2 promotion invariants.

`tamoz-evals` is a fifth, non-runtime development/release gem. It exists from M0 because the
framework invariants, agent behavior, self-improvement promotion, and release decision need
one versioned evidence system. No production dependency points to it.

## Evidence used

- Ruby's `Kernel#throw` searches the active execution stack and raises
  `UncaughtThrowError` without a matching `catch`:
  <https://ruby-doc.org/core/Kernel.html>
- LangGraph documents node restart and the requirement for idempotent effects around
  interrupts:
  <https://docs.langchain.com/oss/python/langgraph/interrupts>
- LangGraph's durable execution guidance likewise requires stable tasks and idempotent
  effects:
  <https://docs.langchain.com/oss/javascript/langgraph/functional-api>
- RubyLLM now has a first-class `Agent` configuration API:
  <https://rubyllm.com/agents/>
- Ruby 3.2 is end-of-support; supported branches are listed at:
  <https://docs.ruby-lang.org/en/>
- SQLite serializes writers even in WAL mode:
  <https://www.sqlite.org/isolation.html>
- OWASP recommends explicit secret lifecycle controls and preventing secrets from entering
  logs and durable artifacts:
  <https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html>
- MCP defines transport/context exchange but leaves host use and policy to the application;
  the official Ruby SDK owns protocol compatibility:
  <https://modelcontextprotocol.io/docs/learn/architecture> and
  <https://github.com/modelcontextprotocol/ruby-sdk>
- Agent Skills defines portable `SKILL.md` trees and progressive disclosure:
  <https://agentskills.io/specification>
- Fugit provides strict Ruby cron calculation with IANA timezone semantics:
  <https://github.com/floraison/fugit>
- The latest local Agentic Stream design separates a deterministic Situation Runtime,
  bounded cognition, governed action, and control/replay:
  [STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md)
- Flink documents event time, watermarks, source idleness, and late evidence:
  <https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/time/>
- OPC UA defines ordinary PubSub separately from functional-safety communication:
  <https://reference.opcfoundation.org/specs/OPC-10000-14/1> and
  <https://reference.opcfoundation.org/specs/OPC-10000-15/4>

## Remaining decisions

The implementation still needs owner input on standalone-first versus Rails-first and Tamoz
Agent's first interactive product shape. The first physical deployment also needs a named
environment, source, hazard analysis, external controller/interlocks, and qualified owner.
Those change packaging and sequencing, not the corrected runtime semantics. They remain in
[DECISIONS.md](DECISIONS.md).
