# Decisions

Architecture decision records and the remaining product questions. Framework and
reference-agent names are settled by ADR-001, standalone-first by ADR-002, and repository
shape by ADR-040.

## Open questions — need your input

These select later product adapters. They do not block the standalone M0 foundation.

### Q1. What physical environment should Tamoz Agent help first?

[TAMOZ_AGENT_DESIGN.md](TAMOZ_AGENT_DESIGN.md) §8 assumes a *coding* agent (read a spec, fix
it, run tests) for the v0.1 durable-runtime proof. The first post-v0.1 product milestone is
physical-world supervision through `tamoz-stream`, but the concrete source and hazard model
remain open: home/environment monitoring, equipment health, inventory/location, or another
domain. Naming the environment, read-only source, desired outcome, existing
controller/interlocks, and accountable operator selects the first connector, SituationSpec,
protected evaluation set, and deployment safety review. The framework semantics do not.

### Q2. How much do you want the research report finished?

Chapters 5–8 of the study were never written. This folder delivers their *content* as design
docs. Producing the polished report and `.docx` as originally planned is separate work of a
few days. Worth doing if it has an audience beyond you; skippable if not.

## Accepted decisions

### ADR-001 — Tamoz framework and Tamoz Agent reference application
**Status:** accepted 2026-07-30.
The framework is **Tamoz**: Ruby namespace `Tamoz`, CLI `tamoz`, require paths `tamoz/*`,
and gems prefixed `tamoz-`. The reference application is **Tamoz Agent**. Public prose uses
the qualified name so the framework and product remain distinguishable; application-owned
Ruby code lives under `Tamoz::App`, while reusable agent recipes remain under
`Tamoz::Agent`.

The rename is intentionally breaking because no runtime package has shipped. No compatibility
aliases preserve the former working names. A web-index check found no obvious exact collision,
but it is not proof of package or trademark availability. M0 must reserve the exact RubyGems
names and project organization and record a trademark/domain check before public release.

### ADR-002 — Four v0.1 runtime gems; optional packages earn promotion
**Status:** revised after architecture review.
v0.1 ships `tamoz-core`, `tamoz-graph`, `tamoz-sqlite`, and `tamoz-agent`. Tamoz Agent is the
reference application. The product is standalone-first; Rails/ActiveRecord and
`tamoz-chain` require real demand. MCP, scheduling, and streaming have accepted optional
package designs and must pass their promotion gates. `tamoz-graph` remains LLM-independent
(invariant 11).
*Earlier decision superseded:* the “six gems” description actually named seven or more
packages and conflicted with the plan's own consumer-driven rule.

### ADR-003 — Reuse RubyLLM public values at runtime; define a lossless durable codec
**Status:** accepted.
`tamoz-core` defines *protocols* (duck types) and ships plain defaults; `tamoz-agent` passes
`RubyLLM::Message` and `RubyLLM::Tool` through public APIs. Durable state still needs a
versioned codec and immutable snapshot; fixtures prove it preserves tool-call ids, content
blocks, citations, attachments, and unknown provider fields.
*Alternative rejected:* a reduced Tamoz message wrapper that drops provider fidelity.

### ADR-004 — Explicit `Tamoz.seq`; no native `Proc#>>`
**Status:** revised after executable counterexample.
Native `Proc#>>` passes only the first Proc's result to the second and loses Tamoz's required
`context` argument. `Tamoz.seq` is the only proposed canonical composition API, and
`Tamoz.step` adapts two-argument callables. `tamoz-chain` itself is deferred.

### ADR-005 — Interrupt by `throw`, not by exception
**Status:** accepted.
LangGraph's documentation has to *ask* users never to wrap `interrupt()` in a bare
`try/except`. In Ruby, `throw` cannot be caught by `rescue`, so the most-violated rule in
that framework becomes structurally impossible here. The matching `catch` must wrap the
node inside each worker; a coordinator catch cannot receive a throw from another thread.

### ADR-006 — Plain Hash state with an explicit reducer registry
**Status:** accepted.
`state :message_events, reduce: Tamoz::Reducers.message_events` rather than type-annotation
metaprogramming.
Hashes are Ruby's record type, pattern matching reads them natively, and the reducer is
visibly a lambda rather than hidden in an `Annotated[...]`.
*Alternative rejected:* `Data`/`Struct`-typed state. Better introspection, but partial
updates against a fixed-shape value object are awkward, and every node would need to
construct one.

### ADR-007 — Frozen state handed to nodes
**Status:** accepted.
Diverges from `ruby_llm`'s mutable fluent style, deliberately. Durable values are normalized,
copied, and recursively frozen at commit. Unsupported mutable objects fail before
execution. Shallow `Data`/Hash freeze alone is insufficient.

### ADR-008 — `:threads` as the default pool, `:inline` in tests
**Status:** accepted.
Agent work is network-bound, so the GVL is released during the waits that matter. `:inline`
is the deterministic debugging mode and the test default. `:fibers` requires `async`, lazily.
All three are observationally equivalent by conformance test — that equivalence is the
reason the default can be changed later without fear.

### ADR-009 — Prompt-cache stability as invariant 16
**Status:** accepted.
The one clause with no LangGraph ancestor. Its failure mode is invisible — nothing breaks,
nothing logs, and the bill multiplies — which is exactly when a machine-checked invariant
beats a documented guideline. `cache_epoch` makes every invalidation attributable to a turn.
*Risk accepted:* it constrains the design. Toolsets cannot change freely mid-session and
history cannot be rewritten outside compaction. Both restrictions are correct anyway.

### ADR-010 — Ruby 3.3 floor; 3.4 and 4.0 primary targets
**Status:** revised after support-status review.
Ruby 3.2 reached end-of-support before this design date. CI covers MRI 3.3, 3.4, and 4.0.
Ruby 3.3 may be dropped after its EOL while Tamoz remains pre-1.0. JRuby enters CI only after
the SQLite/concurrency adapters pass without conditional semantics.

### ADR-011 — SQLite as Tamoz Agent's default persistence
**Status:** accepted.
Single file, no server, WAL, and appropriate for one operator. WAL still permits only one
writer, so transactions stay short and busy retries are bounded. The adapter owns leases,
fencing, connection lifecycle, backup/restore, and file-descriptor tests.

### ADR-012 — MCP is a deferred integration strategy
**Status:** superseded in detail by ADR-029; post-v0.1 timing retained.
Ruby will not out-integrate larger ecosystems, and core ships no integration warehouse.
`tamoz-mcp` is promoted with Tamoz Agent's first real server and must pass local authorization,
effect-safety, credential, supervision, and cache-epoch contracts.

### ADR-013 — Public vocabulary budget, never a correctness cap
**Status:** revised after architecture review.
The twelve concepts remain the introductory learning surface. Operational concepts such as
leases, effect receipts, graph versions, and request ids appear only when their feature is
used. A concept requires justification, but no numeric cap may erase a necessary failure
boundary.

### ADR-014 — No plugin API in v0.1
**Status:** accepted.
Skills and MCP cover the extension need. A plugin API is a compatibility commitment, and
making one before the core stops moving means either breaking it or freezing the core early.
Both reference systems have large plugin surfaces; both also have the maintainer count to
support them.

### ADR-015 — Durable means synchronous barrier commit
**Status:** accepted.
A durable graph returns from a barrier only after its checkpoint commits. v0.1 has no
“async durable” mode. Ephemeral execution is explicit and makes no resume guarantee.

### ADR-016 — External effects are at-least-once unless proven otherwise
**Status:** accepted.
Every effect has a deterministic key and safety class. Idempotent/transactional effects can
converge once. Ambiguous non-idempotent effects become `:unknown` and pause; they are never
retried blindly. Exactly-once arbitrary remote effects are explicitly out of scope.

### ADR-017 — One fenced writer per thread namespace
**Status:** accepted.
Backends grant renewable leases with monotonic fencing tokens. Every pending write and
checkpoint commit validates the fence and base checkpoint. This prevents concurrent
history advancement and zombie commits.

### ADR-018 — Strict sequence is separate from checkpoint identity
**Status:** accepted.
UUIDv7/ULID may be used for opaque ids, but a backend-assigned integer sequence orders
checkpoints within `(thread_id, ns)`. Correctness never depends on wall-clock or lexical UUID
ordering.

### ADR-019 — Resume is graph-version checked
**Status:** accepted.
Checkpoint format version, graph name/version, and definition digest are persisted. An
incompatible resume fails before user code unless an explicit migration appends a compatible
checkpoint.

### ADR-020 — Sensitive data policy is explicit and lossless
**Status:** accepted.
The serializer never scrubs fields by key-name regex. It rejects secret wrappers by default,
supports explicit sensitive fields and authenticated encryption, and applies one redaction
policy across checkpoints, streams, logs, traces, errors, and `inspect`.

### ADR-021 — Resume preserves execution identity; fork changes it
**Status:** accepted.
`execution_id` scopes work to a turn. Within it, a stable logical activation id survives
interrupt, retry, crash resume, and lease takeover; a separate attempt id binds one
invocation to its base checkpoint. Pending writes and effects use logical activation
identity so recorded work is reused, while the barrier validates attempt identity against
the current base. A new external turn or fork creates a new execution id so work from the
source cannot leak into intentional re-execution. Effect-bearing forks require an explicit
replay policy.

### ADR-022 — Every task action requires a reviewed plan
**Status:** accepted 2026-07-30.
Every new user, scheduled, delegated, or internally generated task produces a persisted
plan, even when the proportionate plan is one step. Deterministic structural and semantic
review passes always run; medium/high-risk or complex plans use an independent critic role,
and human review remains policy based. The accepted review binds the canonical plan digest.
When material evidence is missing, an accepted bounded discovery plan may use only locally
classified read-only capabilities; its evidence feeds a separately reviewed action plan.
Discovery cannot mutate, delegate, execute scripts, or authorize later action. Material
change creates a new version and blocks further task action until re-reviewed; crash resume
reuses the checkpointed exact version.
*Alternative rejected:* relying on a system-prompt instruction to “plan first.” It is not
durable, inspectable, or enforceable across tools, subagents, resume, and replanning.

### ADR-023 — Self-improvement is candidate promotion, never live self-mutation
**Status:** accepted 2026-07-30.
Trajectories may generate memories, heuristics, prompts, skills, policies, configuration, or
code candidates. A distinct holdout evaluation, immutable provenance, policy gate, behavior
version, monitoring, and rollback are mandatory. Capability/security/evaluator/
prompt-hierarchy/code changes require human approval and generated content cannot approve
itself. Resume pins the behavior version recorded in the checkpoint.
*Alternative rejected:* letting the running agent rewrite its own active prompt, evaluator,
policy, or code. That makes regressions unauditable and lets the candidate redefine success.

### ADR-024 — “Smart” means evidence-based, proportional, and verified
**Status:** accepted 2026-07-30.
The design does not promise general intelligence or universal model superiority. Smart
behavior is operationally defined: reduce consequential uncertainty, distinguish evidence
from inference, choose the simplest high-value action under risk/cost/time budgets, ask when
guessing would matter, verify material outcomes independently when possible, and stop at the
definition of done. Evaluation measures success, calibration, verification, unnecessary
actions, corrections, safety, latency, and cost.

### ADR-025 — Evaluation is a first-class non-runtime gem
**Status:** accepted 2026-07-30.
`tamoz-evals` ships from M0 as the owner of executable invariant suites, behavioral cases,
canonical evaluation artifacts, paired baseline comparison, protected-holdout policy, and
release gates. It can exercise every Tamoz public boundary, but no runtime gem or application
runtime depends on it. Safety/correctness are hard gates, not weighted score inputs; model
judges are fallible evidence after deterministic scorers; every evaluator change starts a
new lineage.

The public gem includes conformance and development cases. Tamoz Agent release holdouts are
provided to an isolated evaluation worker outside the public repository and remain
unavailable to the subject and self-improvement worker.
*Alternative rejected:* leaving evaluation as milestone-local RSpec files and prose. That
cannot reproduce a release decision, protect a holdout, or prevent a self-improving agent
from redefining its own success.

### ADR-026 — Three durable memory layers: Experience, Knowledge, Wisdom
**Status:** accepted 2026-07-30.
Current task context remains checkpointed working state, not durable memory. Cross-session
memory has three explicit layers: grounded Experience, curated Knowledge, and evaluated
Wisdom. Episodic/semantic/procedural describe record classes within those layers. Promotion
is an auditable state transition; repetition does not turn a claim into fact, and Wisdom
cannot activate without `tamoz-evals` and a behavior-version transition.
*Alternative rejected:* one vector store containing chat, facts, procedures, and learned
policy. It erases authority, lifecycle, retrieval, and evaluation differences.

### ADR-027 — Memory retrieval is authorization; consolidation preserves disagreement
**Status:** accepted 2026-07-30.
Scope, tenant/user/surface authority, sensitivity, layer/class, active state, validity, and
compatibility filter candidates before ranking. Experience is never auto-injected;
Knowledge automatic recall is narrow; Wisdom is pinned by behavior version. Consolidation
keeps source links, contradiction sets, exceptions, and preimages. Correction, supersession,
quarantine, and deletion propagate to every recall path with receipts.
*Alternative rejected:* relevance-first retrieval followed by model-side filtering. Merely
exposing an unauthorized or stale record to ranking/context has already crossed the
boundary.

### ADR-028 — Self-healing is bounded remediation, not catch-and-retry
**Status:** accepted 2026-07-30.
Deterministic runtime recovery, bounded remediation, and systemic self-improvement remain
separate mechanisms. Automatic remediation requires a typed failure, versioned rule,
reviewed exact plan, proven preconditions, original authority, effect-safe identity,
budgets, independent verification, compensation/containment, and a durable circuit.
Rules earn authority through replay, shadow, isolated fault injection, canary, and active
stages in `tamoz-evals`; they cannot promote or reset themselves.
*Alternative rejected:* free-form error interpretation and “try something else.” The local
OpenClaw audit showed why missing reads, directory reads, and stale edits do not authorize
file creation, directory listing substitution, or whole-file replacement.

### ADR-029 — MCP is native at the edge and uses the official Ruby SDK
**Status:** accepted 2026-07-30; implementation post-v0.1.
`tamoz-mcp` is an optional first-class host/server package. It uses the official `mcp` gem
for protocol, transports, OAuth, and schemas while Tamoz owns local policy, effect identity,
durable elicitation, content bounds, supervision, catalog epochs, and evaluation.
`2026-07-28` is the current protocol target; `2025-11-25` is the initial compatibility
baseline until the selected Ruby SDK fully implements the required 2026 multi-round-trip
flow and Tamoz conformance passes.
*Alternative rejected:* implementing JSON-RPC/MCP inside Tamoz. It duplicates a fast-moving
standard and couples graph correctness to protocol churn.

### ADR-030 — One local capability catalog governs local tools, MCP, and skills
**Status:** accepted 2026-07-30.
Capabilities use source-qualified content-addressed descriptors. The application—not a
remote server, skill, memory, or model—assigns trust, effect class, scope, and authority.
Effective access is the intersection of current application, agent, accepted-plan,
parent/schedule, and source limits. Epoch changes occur only at explicit turn boundaries.
*Alternative rejected:* importing MCP annotations or skill `allowed-tools` as permissions.
Both are content from a different trust boundary and can only request or narrow authority.

### ADR-031 — Scheduling materializes occurrences; it does not run agents
**Status:** accepted 2026-07-30; implementation post-v0.1.
`tamoz-scheduler` owns strict time calculation and durable occurrence identity. A due
occurrence is atomically claimed and delivered to the existing request inbox with a stable
request id; the ordinary Tamoz Agent graph then plans, reviews, executes, and verifies it.
Delivery success and task success remain separate.
*Alternative rejected:* putting model calls or business execution in a timer callback.
Process timers are not durable, and mixing delivery with execution makes crash and duplicate
semantics impossible to state honestly.

### ADR-032 — Scheduled time and delayed authority are explicit
**Status:** accepted 2026-07-30.
Cron requires a pinned IANA timezone. DST gap/fold, misfire, overlap, jitter, catch-up,
concurrency, and backlog are stored bounded policies. Schedule revisions are immutable and
occurrence identity includes the revision and nominal UTC instant. A job pins maximum
capabilities, budgets, behavior adoption, approval/escalation, and delivery; run-time
authority intersects current policy so revocation always wins.
*Alternative rejected:* host-timezone cron with “run missed jobs on startup” and inherited
current agent permissions. It creates DST surprises, restart storms, and delayed privilege
escalation.

### ADR-033 — Skills use the open Agent Skills format and stay in `tamoz-agent`
**Status:** accepted 2026-07-30.
Tamoz consumes portable `SKILL.md` directories with progressive disclosure. Extensions live
under versioned flat `tamoz.*` metadata keys with string values. Skills remain an agent
recipe/resource concern rather than a new gem because they introduce no independent
execution engine. Loading a skill is inert; scripts execute only through ordinary reviewed
tools.
*Alternative rejected:* a Tamoz-only skill DSL or plugin API. It sacrifices portability and
turns instruction packaging into a premature executable extension surface.

### ADR-034 — Skill identity is a tree digest and activation is supply-chain promotion
**Status:** accepted 2026-07-30.
The executable identity is source-qualified name plus canonical tree digest, not a path or
self-claimed version. Same-name cross-source collisions require explicit binding. Install
and update stage in quarantine, validate paths/archives/provenance/capability changes, run
comparative evaluation, and activate atomically as a new catalog/cache epoch. Generated
skills are candidates and cannot evaluate or approve themselves.
*Alternative rejected:* watching mutable skill directories and loading the newest bytes on
resume. That makes behavior unreproducible and enables silent shadowing and same-version
supply-chain swaps.

### ADR-035 — Streaming input is a distinct first-class `tamoz-stream` runtime
**Status:** accepted 2026-07-30.
Unbounded evidence does not enter `tamoz-graph` or a model directly. `tamoz-stream` owns
channel admission, temporal/keyed state, immutable Situations, cognition admission, and
replay. It depends on core contracts, not graph/agent/RubyLLM; `tamoz-sqlite` implements its
first StreamStore. Execution `StreamPart`s, user channels, and scheduler occurrences retain
their separate semantics.
*Alternative rejected:* rename token/tool streaming as bidirectional streaming and attach
sensor callbacks to a long-running chat. It has no temporal truth, bounded state, or
deterministic recovery model.

### ADR-036 — Situation is the boundary between continuous evidence and episodic cognition
**Status:** accepted 2026-07-30.
Deterministic operators reduce authenticated events into immutable versioned Situations.
Persisted bounded admission starts at most one agent episode against an exact snapshot;
new evidence may supersede it. Every non-admission is also durable and explainable.
*Alternative rejected:* invoke the agent per event or drain raw windows into prompts. Both
maximize cost and staleness while moving deterministic stream semantics into probabilistic
cognition.

### ADR-037 — Event time, explicit backpressure, and effect-disabled replay are contracts
**Status:** accepted 2026-07-30.
Channel revisions declare event-time/watermark/late/idleness policy, bounded state and
overflow semantics. At-least-once sources are acknowledged after durable admission and use
application event identity. Replay virtualizes time and has no production effector
credentials; its four modes are deterministic, recorded-cognition, shadow, and
counterfactual simulation.
*Alternative rejected:* rely on broker QoS and processing time. Transport delivery does not
define application deduplication, temporal completeness, physical outcomes, or safe replay.

### ADR-038 — Physical action is typed intent plus current-state policy, never model effect
**Status:** accepted 2026-07-30.
The model separates facts from inference and proposes typed ActionIntents. Deterministic
policy reloads current Situation/device state, then checks freshness, scope, bounds, quota,
approval, expiry, evidence completeness/quality/quorum, source health/calibration/gaps,
idempotency/reconciliation, and external interlocks before journaling a narrow Command.
R2/R3 fail closed on insufficient or contradictory evidence. Approval does not bypass
revalidation.
*Alternative rejected:* expose actuator tools to the model with a confirmation prompt.
Prompt injection, stale state, duplicate effects, and human approval fatigue remain
uncontrolled.

### ADR-039 — Tamoz is supervisory; certified safety and real-time control stay external
**Status:** accepted 2026-07-30.
The first physical-world profile observes, diagnoses, recommends, and may perform explicitly
granted bounded reversible commands through independently safe automation. R4
life/safety-critical control is advisory-only. Emergency stops, guarding, motion/PLC loops,
functional-safety communication, and interlocks remain external, authoritative, and
impossible for self-healing or self-improvement to weaken.
*Alternative rejected:* market a general agent framework as a robot/safety controller.
Tamoz has neither hard real-time semantics nor domain certification, and an LLM cannot be
the final safety barrier.

### ADR-040 — One monorepo, multiple independently publishable gems
**Status:** accepted 2026-07-30.
Tamoz uses one repository for framework gems, Tamoz Agent, conformance fixtures, examples,
and release tooling. Each gem has an explicit manifest and dependency boundary and can be
packaged independently. Before 1.0, releases are coordinated through one compatibility
matrix but versions change only for affected gems; optional feature/SQLite contract
versions are tested as explicit pairs. Repository proximity grants no runtime dependency.
*Alternative rejected:* separate repositories from the first commit. That multiplies
cross-repository changes, CI, fixtures, and release coordination before ownership or release
cadence has actually diverged.

## Rejected, with reasons

| Rejected | Why |
|---|---|
| Port LangChain's `Runnable` faithfully | Sixteen methods, async twins, and a base class to express what duck typing gives free |
| A `Memory` abstraction | Three LangChain rewrites all concluded state must be explicit and injected. Start at the conclusion |
| Supervisor / swarm / hierarchy classes | Recipes over the engine. Shipping topology classes means the engine has started guessing what agents are |
| Document loaders in core | The single largest source of LangChain's dependency bloat. Ruby has good gems per format |
| `Marshal` as the default serializer | A checkpoint file is a durable artifact; `Marshal.load` on it is remote code execution waiting for a bad day |
| An async/await API alongside the sync one | One API with ordered pool selection; fibers remain optional |
| Config-dict behaviour dispatch (`config["configurable"]["llm"]`) | Stringly-typed action at a distance, on the criticism list. Keyword arguments |
| A `Tamoz::Message` that wraps `RubyLLM::Message` | See ADR-003 |
| Building the framework without building the agent | The agent is the only honest specification. See [GOAL.md](GOAL.md) |
| UUID lexical order as checkpoint sequence | It is not a concurrency or clock-safe append order; see ADR-018 |
| Regex-based secret scrubbing | It is lossy and incomplete; see ADR-020 |
| Blind retry after an ambiguous side effect | It can duplicate irreversible work; see ADR-016 |
| Prompt-only “always plan” instruction | It cannot enforce an action gate or prove which plan authorized execution; see ADR-022 |
| Live self-rewriting agent | It can change its evaluator or permissions and hide regressions; see ADR-023 |
| “Smart” as an unmeasured personality claim | It rewards confident prose rather than correct, efficient outcomes; see ADR-024 |
| Evaluation only as scattered test files | It cannot own versioned corpora, baselines, judge lineage, or release evidence; see ADR-025 |
| `tamoz-evals` in the production dependency graph | Evaluation must observe behavior without changing it; see ADR-025 |
| Chat/vector store as one memory system | It collapses Experience, Knowledge, Wisdom, authority, and lifecycle; see ADR-026 |
| Relevance-first memory security | Unauthorized data has already leaked before model-side filtering; see ADR-027 |
| Generic catch-and-retry “self-healing” | It cannot prove authority, effect state, invariant recovery, or bounded harm; see ADR-028 |
| Custom MCP protocol implementation | The official SDK owns wire compatibility; Tamoz owns host semantics; see ADR-029 |
| Remote metadata as capability policy | Server/skill content cannot grant or lower local authority; see ADR-030 |
| Agent execution inside timer callbacks | Scheduling delivers stable requests; the graph executes them; see ADR-031 |
| Implicit host-timezone cron and unbounded catch-up | Time, DST, misfire, overlap, and backlog must be explicit; see ADR-032 |
| Tamoz-only skill DSL or early plugin API | The portable Agent Skills format plus ordinary tools is sufficient; see ADR-033 |
| Mutable path/version as skill identity | Reproducible behavior requires canonical tree digests and staged activation; see ADR-034 |
| Feeding sensors into a persistent chat | Continuous evidence needs event time, bounds, replay, and admission before cognition; see ADR-035 and ADR-036 |
| Broker QoS as end-to-end exactly-once | Transport acknowledgement cannot atomically prove application state or physical outcome; see ADR-037 |
| Actuator tools directly exposed to the model | Physical effects require typed intent and current deterministic policy; see ADR-038 |
| Tamoz as a certified safety/motion controller | Supervisory cognition cannot replace functional safety or hard real-time control; see ADR-039 |
