# Core decisions — the foundational ADR log

This is the single living record of Tamoz's **in-force foundational decisions** — the stable
runtime, agent, and subsystem axioms that are stated as one rule and rarely change. It
replaces the monolith `docs/design-v0.1/DECISIONS.md` as the source of truth for these
decisions (that file was removed on 2026-08-29 once its content was migrated here).

Decisions that carry a threat model, a change-bar, or an amendment history are **standalone
pages**, not log entries — see the [catalog](./README.md). Superseded/retired decisions are in
[`RETIRED.md`](./RETIRED.md). Grading and tiers are defined in
[`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md).

Each entry is graded at its tier; every implemented decision carries a dated **Verified**
line. Reality checks were performed 2026-08-29 against the shipped tree.

Current version: `0.1.0.alpha.1` (pre-release).

---

## Identity & framework shape

### ADR-001 — The framework is Tamoz; the reference application is Tamoz Agent
**Status:** Accepted 2026-07-30.
Ruby namespace `Tamoz`, CLI `tamoz`, require paths `tamoz/*`, gems prefixed `tamoz-`.
Application-owned code lives under `Tamoz::App`; reusable agent recipes under `Tamoz::Agent`.
The rename was intentionally breaking (no runtime package had shipped); no compatibility
aliases preserve former names.
**Open action:** reserve the exact RubyGems names and record a trademark/domain check before
public release (audit item O2).
**Verified:** 2026-08-29 — the `Tamoz::` namespace and `tamoz-*` gem prefix hold across all 27
gems.

### ADR-004 — Explicit `Tamoz.seq`; no native `Proc#>>`
**Status:** Accepted (revised after an executable counterexample).
Native `Proc#>>` passes only the first proc's result and loses Tamoz's required `context`
argument. `Tamoz.seq` is the canonical composition API; `Tamoz.step` adapts two-argument
callables. `tamoz-chain` itself is deferred until a real consumer proves graph + ordinary Ruby
composition is insufficient.
**Verified:** 2026-08-29 — `tamoz-chain` is absent from the tree (correctly deferred).

### ADR-013 — Public vocabulary is a budget, never a correctness cap
**Status:** Accepted (revised after review).
The twelve introductory concepts are the learning surface; operational concepts (leases,
effect receipts, graph versions, request ids) appear only when their feature is used. A
concept needs justification, but no numeric cap may erase a necessary failure boundary.

### ADR-014 — No plugin API in v0.1
**Status:** Accepted. *(Tier F — bounds the extension surface.)*
Skills and MCP cover the extension need. A plugin API is a compatibility commitment made
before the core stops moving. The capability registry is instead a **closed set** of built-in
sources (ADR-030, ADR-054); adding one is a gem release, not a plugin.
**Verified:** 2026-08-29 — product.md documents the closed four-source registry; no plugin
entry point exists.

---

## Durable runtime & graph engine

### ADR-005 — Interrupt by `throw`, not by exception
**Status:** Accepted.
In Ruby, `throw` cannot be caught by `rescue`, so LangGraph's most-violated rule ("never wrap
`interrupt()` in a bare `try/except`") becomes structurally impossible. The matching `catch`
wraps the node inside each worker; a coordinator catch cannot receive a throw from another
thread.

### ADR-006 — Plain Hash state with an explicit reducer registry
**Status:** Accepted.
`state :message_events, reduce: Tamoz::Reducers.message_events` — not type-annotation
metaprogramming. Hashes are Ruby's record type and pattern-match natively; the reducer is a
visible lambda.
*Rejected:* `Data`/`Struct`-typed state — partial updates against a fixed-shape value object
are awkward and every node would construct one.

### ADR-007 — Frozen state is handed to nodes
**Status:** Accepted.
Durable values are normalized, copied, and recursively frozen at commit; unsupported mutable
objects fail before execution. Shallow freeze alone is insufficient.
**Verified:** 2026-08-29 — `Tamoz::Core.deep_freeze` is present and high-fan-in (enola: 34
dependents).

### ADR-008 — `:threads` is the default pool; `:inline` in tests
**Status:** Accepted.
Agent work is network-bound, so the GVL releases during the waits that matter. `:inline` is the
deterministic debug/test default; `:fibers` requires `async`, lazily. All three are
observationally equivalent by conformance test — which is why the default can change later.
**Verified:** 2026-08-29 — `Tamoz::Pool::Threads` is present.

### ADR-009 — Prompt-cache stability is invariant 16
**Status:** Accepted. *(Tier F — a cost/safety invariant.)*
Its failure mode is invisible (nothing breaks, nothing logs, the bill multiplies), so a
machine-checked invariant beats a guideline. `cache_epoch` makes every invalidation
attributable to a turn.
*Risk accepted:* toolsets cannot change freely mid-session and history cannot be rewritten
outside compaction — both correct anyway.

### ADR-010 — Ruby 3.3 floor; 3.4 and 4.0 primary targets
**Status:** Accepted (revised after support-status review).
Ruby 3.2 reached end-of-support before the design date. CI covers MRI 3.3, 3.4, 4.0; 3.3 may be
dropped after its EOL while pre-1.0. JRuby enters CI only after the SQLite/concurrency adapters
pass without conditional semantics.
**Re-verify:** the CI matrix and `.ruby-version` currency (audit ⚠️).

### ADR-011 — SQLite is Tamoz Agent's default persistence
**Status:** Accepted.
Single file, no server, WAL, one operator. WAL permits one writer, so transactions stay short
and busy retries are bounded. The adapter owns leases, fencing, connection lifecycle,
backup/restore, and file-descriptor tests.
**Verified:** 2026-08-29 — `tamoz-sqlite` present; `Tamoz::SQLite::Adapter` high-fan-in.

### ADR-015 — Durable means synchronous barrier commit
**Status:** Accepted. *(Tier F.)*
A durable graph returns from a barrier only after its checkpoint commits. There is no "async
durable" mode in v0.1; ephemeral execution is explicit and makes no resume guarantee.

### ADR-016 — External effects are at-least-once unless proven otherwise
**Status:** Accepted. *(Tier F — the honest-durability boundary.)*
Every effect has a deterministic key and safety class. Idempotent/transactional effects
converge once; ambiguous non-idempotent effects become `:unknown` and pause — never retried
blindly. Exactly-once arbitrary remote effects are explicitly out of scope.
*Rejected:* blind retry after an ambiguous side effect — it can duplicate irreversible work.

### ADR-017 — One fenced writer per thread namespace
**Status:** Accepted. *(Tier F.)*
Backends grant renewable leases with monotonic fencing tokens; every pending write and
checkpoint commit validates the fence and base checkpoint. This prevents concurrent history
advancement and zombie commits.

### ADR-018 — Strict sequence is separate from checkpoint identity
**Status:** Accepted.
Opaque ids may be UUIDv7/ULID, but a backend-assigned integer sequence orders checkpoints
within `(thread_id, ns)`. Correctness never depends on wall-clock or lexical UUID ordering.
*Rejected:* UUID lexical order as sequence — not a concurrency- or clock-safe append order.

### ADR-019 — Resume is graph-version checked
**Status:** Accepted. *(Tier F.)*
Checkpoint format version, graph name/version, and definition digest are persisted; an
incompatible resume fails before user code unless an explicit migration appends a compatible
checkpoint.

### ADR-020 — Sensitive-data policy is explicit and lossless
**Status:** Accepted. *(Tier F — the redaction boundary.)*
The serializer never scrubs by key-name regex. It rejects secret wrappers by default, supports
explicit sensitive fields and authenticated encryption, and applies one redaction policy across
checkpoints, streams, logs, traces, errors, and `inspect`.
*Rejected:* regex-based secret scrubbing — lossy and incomplete.
**Verified:** 2026-08-29 — `Tamoz::Core.secret_shaped?` present (11 dependents).

### ADR-021 — Resume preserves execution identity; fork changes it
**Status:** Accepted. *(Tier F.)*
`execution_id` scopes work to a turn; within it a stable logical activation id survives
interrupt, retry, crash resume, and lease takeover, while a separate attempt id binds one
invocation to its base checkpoint. A new external turn or fork creates a new execution id so
source work cannot leak into intentional re-execution. Effect-bearing forks require an explicit
replay policy.

---

## Agent deliberation & learning

> The two safety-spine decisions of this group are standalone pages:
> [ADR-022 — every task action requires a reviewed plan](./adr-022-reviewed-plan-gate.md) and
> [ADR-023 — self-improvement is candidate promotion](./adr-023-self-improvement-promotion.md).

### ADR-024 — "Smart" means evidence-based, proportional, and verified
**Status:** Accepted 2026-07-30. *(Tier F — defines the product claim.)*
No promise of general intelligence. Smart behavior is operationally defined: reduce
consequential uncertainty, distinguish evidence from inference, choose the simplest high-value
action under budgets, ask when guessing would matter, verify material outcomes independently,
and stop at the definition of done. Evaluation measures success, calibration, verification,
unnecessary actions, corrections, safety, latency, and cost.
*Rejected:* "smart" as an unmeasured personality claim — it rewards confident prose over
correct, efficient outcomes.

### ADR-025 — Evaluation is a first-class non-runtime gem
**Status:** Accepted 2026-07-30. *(Tier F.)*
`tamoz-evals` owns executable invariant suites, behavioral cases, canonical artifacts, paired
baseline comparison, protected-holdout policy, and release gates. It can exercise every public
boundary, but **no runtime gem depends on it**. Safety/correctness are hard gates, not weighted
scores; model judges are fallible evidence after deterministic scorers; every evaluator change
starts a new lineage.
*Rejected:* evaluation as scattered test files — cannot own versioned corpora, baselines, judge
lineage, or release evidence, or stop a self-improving agent redefining success.
**Verified:** 2026-08-29 — `tamoz-evals` present (with `tamoz-evals-runner`; see audit O3); no
runtime gem depends on it.

### ADR-026 — Three durable memory layers: Experience, Knowledge, Wisdom
**Status:** Accepted 2026-07-30. *(Tier F.)*
Current task context stays checkpointed working state, not durable memory. Cross-session memory
has three layers — grounded Experience, curated Knowledge, evaluated Wisdom. Promotion is an
auditable state transition; repetition does not turn a claim into fact; Wisdom cannot activate
without `tamoz-evals` and a behavior-version transition.
*Rejected:* one vector store for chat, facts, procedures, and learned policy — it erases
authority, lifecycle, retrieval, and evaluation differences.
**Verified:** 2026-08-29 — `tamoz-agent-memory` present.

### ADR-027 — Memory retrieval is authorization; consolidation preserves disagreement
**Status:** Accepted 2026-07-30. *(Tier F.)*
Scope, tenant/user/surface authority, sensitivity, layer/class, active state, validity, and
compatibility filter candidates **before** ranking. Experience is never auto-injected;
Knowledge auto-recall is narrow; Wisdom is pinned by behavior version. Consolidation keeps
source links, contradiction sets, exceptions, and preimages; correction/supersession/
quarantine/deletion propagate to every recall path with receipts.
*Rejected:* relevance-first retrieval then model-side filtering — exposing an unauthorized or
stale record to ranking has already crossed the boundary.

### ADR-028 — Self-healing is bounded remediation, not catch-and-retry
**Status:** Accepted 2026-07-30. *(Tier F.)*
Automatic remediation requires a typed failure, versioned rule, reviewed exact plan, proven
preconditions, original authority, effect-safe identity, budgets, independent verification,
compensation/containment, and a durable circuit. Rules earn authority through replay, shadow,
isolated fault injection, canary, and active stages in `tamoz-evals`; they cannot promote or
reset themselves.
*Rejected:* free-form "try something else" — cannot prove authority, effect state, invariant
recovery, or bounded harm.
**Verified:** 2026-08-29 — `tamoz-agent-healing` present.

---

## Extensibility — MCP, skills, scheduling

### ADR-029 — MCP is native at the edge and uses the official Ruby SDK
**Status:** Accepted 2026-07-30; **shipped** (`tamoz-mcp`). *(Tier F.)*
`tamoz-mcp` is an optional first-class host/server package using the official `mcp` gem for
protocol, transports, OAuth, and schemas, while Tamoz owns local policy, effect identity,
durable elicitation, content bounds, supervision, catalog epochs, and evaluation.
*Rejected:* implementing JSON-RPC/MCP inside Tamoz — duplicates a fast-moving standard and
couples graph correctness to protocol churn.
**Verified:** 2026-08-29 — `tamoz-mcp` and `tamoz-mcp-websearch` present (supersedes the
"deferred/post-v0.1" timing of the retired ADR-012).

### ADR-030 — One local capability catalog governs all sources
**Status:** Accepted 2026-07-30; **extended by [ADR-054](./adr-054-websearch-capability-source.md).**
*(Tier F.)*
Capabilities use source-qualified content-addressed descriptors. **The application** — not a
remote server, skill, memory, or model — assigns trust, effect class, scope, and authority.
Effective access is the intersection of current application, agent, accepted-plan,
parent/schedule, and source limits. Epoch changes occur only at explicit turn boundaries. The
closed source set is now **four**: local tools, skills, MCP, and websearch (ADR-054).
*Rejected:* importing MCP annotations or skill `allowed-tools` as permissions — content from a
different trust boundary can only request or narrow authority.
**Verified:** 2026-08-29 — `tamoz-agent-capabilities` present; four sources wired (audit finding
#4).

### ADR-031 — Scheduling materializes occurrences; it does not run agents
**Status:** Accepted 2026-07-30; **shipped** (`tamoz-scheduler`). *(Tier F.)*
`tamoz-scheduler` owns strict time calculation and durable occurrence identity. A due
occurrence is atomically claimed and delivered to the request inbox with a stable request id;
the ordinary agent graph then plans, reviews, executes, and verifies it. Delivery success and
task success stay separate.
*Rejected:* model calls or business execution in a timer callback — process timers are not
durable, and mixing delivery with execution makes crash/duplicate semantics dishonest.
**Verified:** 2026-08-29 — `tamoz-scheduler` present.

### ADR-032 — Scheduled time and delayed authority are explicit
**Status:** Accepted 2026-07-30. *(Tier F.)*
Cron pins an IANA timezone. DST gap/fold, misfire, overlap, jitter, catch-up, concurrency, and
backlog are stored bounded policies. Schedule revisions are immutable; occurrence identity
includes the revision and nominal UTC instant. A job pins maximum capabilities, budgets,
behavior adoption, approval/escalation, and delivery; run-time authority intersects current
policy so revocation always wins.
*Rejected:* host-timezone cron with "run missed jobs on startup" and inherited current
permissions — DST surprises, restart storms, delayed privilege escalation.

### ADR-033 — Skills use the open Agent Skills format and stay an agent recipe
**Status:** Accepted 2026-07-30. *(Tier F.)*
Tamoz consumes portable `SKILL.md` directories with progressive disclosure; extensions live
under versioned flat `tamoz.*` metadata keys. Skills are a recipe/resource concern, not a new
gem — they introduce no independent execution engine. Loading a skill is inert; scripts execute
only through ordinary reviewed tools.
*Note (2026-08-29):* skill *sourcing* now lives in `tamoz-agent-capabilities` (ADR-052), not in
a monolithic `tamoz-agent`; the decision (skills are a recipe, not their own engine) is
unchanged.
*Rejected:* a Tamoz-only skill DSL or plugin API — sacrifices portability and turns instruction
packaging into a premature executable extension surface.

### ADR-034 — Skill identity is a tree digest; activation is supply-chain promotion
**Status:** Accepted 2026-07-30. *(Tier F.)*
Executable identity is source-qualified name plus canonical tree digest, not a path or
self-claimed version. Same-name cross-source collisions require explicit binding. Install/update
stage in quarantine, validate paths/archives/provenance/capability changes, run comparative
evaluation, and activate atomically as a new catalog/cache epoch. Generated skills are
candidates and cannot evaluate or approve themselves.
*Rejected:* watching mutable skill directories and loading newest bytes on resume — makes
behavior unreproducible and enables silent shadowing and same-version supply-chain swaps.

---

## Streaming & physical world

### ADR-035 — Streaming input is a distinct first-class `tamoz-stream` runtime
**Status:** Accepted 2026-07-30; **shipped** (`tamoz-stream`). *(Tier F.)*
Unbounded evidence does not enter `tamoz-graph` or a model directly. `tamoz-stream` owns channel
admission, temporal/keyed state, immutable Situations, cognition admission, and replay. It
depends on core contracts, not graph/agent; `tamoz-sqlite` implements its first StreamStore.
*Rejected:* renaming token/tool streaming as bidirectional streaming and attaching sensor
callbacks to a long-running chat — no temporal truth, bounded state, or deterministic recovery.
**Verified:** 2026-08-29 — `tamoz-stream` present. *(See audit O1: the Ruby worker / Go
authority two-repo split still needs its own ADR.)*

### ADR-036 — Situation is the boundary between continuous evidence and episodic cognition
**Status:** Accepted 2026-07-30. *(Tier F.)*
Deterministic operators reduce authenticated events into immutable versioned Situations.
Persisted bounded admission starts at most one agent episode against an exact snapshot; new
evidence may supersede it. Every non-admission is also durable and explainable.
*Rejected:* invoke the agent per event or drain raw windows into prompts — maximizes cost and
staleness and moves deterministic semantics into probabilistic cognition.

### ADR-037 — Event time, explicit backpressure, and effect-disabled replay are contracts
**Status:** Accepted 2026-07-30. *(Tier F.)*
Channel revisions declare event-time/watermark/late/idleness policy and bounded state/overflow
semantics. At-least-once sources are acknowledged after durable admission using application
event identity. Replay virtualizes time and has no production effector credentials; its four
modes are deterministic, recorded-cognition, shadow, and counterfactual simulation.
*Rejected:* rely on broker QoS and processing time — transport delivery does not define
application dedup, temporal completeness, physical outcomes, or safe replay.

### ADR-038 — Physical action is typed intent plus current-state policy, never model effect
**Status:** Accepted 2026-07-30. *(Tier F — actuator boundary.)*
The model separates facts from inference and proposes typed ActionIntents. Deterministic policy
reloads current Situation/device state, then checks freshness, scope, bounds, quota, approval,
expiry, evidence completeness/quality/quorum, source health/calibration/gaps,
idempotency/reconciliation, and external interlocks before journaling a narrow Command. R2/R3
fail closed on insufficient or contradictory evidence; approval does not bypass revalidation.
**Threat note:** the asset is actuation. The adversary is prompt injection, stale state,
duplicate effects, and approval fatigue; the mitigation is that authority is computed by
deterministic policy over current state, never granted by model output or a bare confirmation.
*Rejected:* expose actuator tools to the model with a confirmation prompt — leaves injection,
stale state, duplicate effects, and approval fatigue uncontrolled.

### ADR-039 — Tamoz is supervisory; certified safety and real-time control stay external
**Status:** Accepted 2026-07-30. *(Tier F.)*
The first physical profile observes, diagnoses, recommends, and may perform explicitly granted
bounded reversible commands through independently safe automation. R4 life/safety-critical
control is advisory-only. Emergency stops, guarding, motion/PLC loops, functional-safety
communication, and interlocks remain external, authoritative, and impossible for
self-healing/self-improvement to weaken.
*Rejected:* marketing a general agent framework as a robot/safety controller — Tamoz has neither
hard real-time semantics nor domain certification, and an LLM cannot be the final safety
barrier.

---

## Repository & packaging

### ADR-040 — One monorepo, multiple independently publishable gems
**Status:** Accepted 2026-07-30; **instantiated by [ADR-052](./adr-052-agent-gem-decomposition.md).**
*(Tier F.)*
One repository for framework gems, Tamoz Agent, conformance fixtures, examples, and release
tooling. Each gem has an explicit manifest and dependency boundary and can be packaged
independently. Before 1.0, releases coordinate through one compatibility matrix but versions
change only for affected gems. **Repository proximity grants no runtime dependency.**
*Rejected:* separate repositories from the first commit — multiplies cross-repo changes, CI,
fixtures, and release coordination before ownership diverged.
**Verified:** 2026-08-29 — 27 gems, per-gem gemspecs. *(Audit O1: the `agentic-stream` Go
authority is a second repo whose relationship to this rule needs an ADR.)*

---

## Communications

### ADR-041 — Communication channels are a contract gem plus per-transport adapter gems
**Status:** Accepted 2026-08-10. *(Tier F.)*
`tamoz-comms` owns the channel vocabulary and seams (surface/message values, identity/admission
policy, rendering, the `Transport` adapter contract, the structural `CommsStore` contract) and
depends only on `tamoz-core`. Each transport is a separate gem passing the `tamoz-comms`
conformance suite; `tamoz-telegram` depends only on `tamoz-comms` and stdlib. The kind list is a
closed set; adding a transport is a `tamoz-comms` release, not a plugin. The worker integrates
through one nil-safe `DeliverySink` and never makes a channel network call.
*Rejected:* a single gem with a lazily-required Telegram backend — leaves the transport seam
untested and forces `net/http` into the contract gem's load graph (ADR-014 stands).
**Verified:** 2026-08-29 — `tamoz-comms` and `tamoz-telegram` present.

### ADR-042 — The channel gateway is a separate process in the connector zone
**Status:** Accepted 2026-08-10. *(Tier F.)*
`tamoz comms serve` is the only long-running Tamoz process that talks to the channel transport.
It holds the transport credential, admits/normalizes inbound updates, writes the durable
disposition, and drains the delivery outbox; it never constructs a `Session`, loads a model
credential, opens a toolbox, or reads workspace files. Both processes share one SQLite runtime
DB so an admission and its request enqueue commit in one transaction.
*Rejected:* the worker performing the send — an outbound network call in the process holding the
model credential, toolbox, and workspace makes the connector-zone boundary aspirational.
**Verified:** 2026-08-29 — `tamoz-comms-gateway` present; `Tamoz::Comms::Gateway` symbol.

### ADR-043 — Telegram v1 is deny-only and reference-bound
**Status:** Accepted 2026-08-10; **amended by [ADR-049](./adr-049-telegram-approval.md).**
*(Tier F.)*
A chat identity is weaker evidence than filesystem access to the 0700 runtime directory, so v1
Telegram surfaces can deny an exact pending interrupt and cannot grant approval. A button
carries an action plus a single-use 128-bit reference; the gateway stores only its
domain-separated digest in an inactive prompt row that activates only after a durable send
receipt, and consumption is atomic against every stored prompt binding. No channel component
answers on a human's behalf; `chat_grants` and `headless_auto_approvals` must both remain zero.
Any future grant mode requires a new ADR, a threat model, and a step-up identity decision — the
bar ADR-049 §4 now defines, and whose invariants (INV-A..INV-E) it states.
*Rejected:* reusing the worker's `(thread, occurrence, granted)` tuple for callbacks — it binds
no actor, interrupt digest, expiry, or consumption.

---

## Observability & model transport

### ADR-044 — Observability is a contract gem plus per-exporter adapter gems
**Status:** Accepted 2026-08-10. *(Tier F.)*
The contract gem owns the signal catalog, recorder, journal, and exporter-adapter seam; each
exporter is a separate adapter gem passing the contract gem's conformance suite. The exporter
list is a closed set; adding one is a contract-gem release, not a plugin (ADR-014 stands).
*Rejected:* an exporter plugin API — an unversioned extension point with no conformance gate on
the one surface that carries telemetry out of the process.
**Verified:** 2026-08-29 — `tamoz-observability` and `tamoz-otel` present.

### ADR-045 — The observability gems add no durable table and no second source of truth
**Status:** Accepted 2026-08-10. *(Tier F.)*
History is the existing durable record plus a bounded rotating journal; authoritative traces are
reconstructed. A telemetry writer would contend with the fenced writer that guards correctness.
Model-usage capture is not an exception — it is a separately authorized persistence change
(OBSERVABILITY_DESIGN §10) that observability consumes. Phase-5 operator-authority records
(silences, rule revisions) are not telemetry and are out of scope (§18.4; ADR-050).
*Rejected:* a durable telemetry table alongside the runtime record — two writers of overlapping
truth drift and contend with the fenced writer.

### ADR-046 — Content capture is off by default, per class, and refused for restricted classes
**Status:** Accepted 2026-08-10. *(Tier F.)*
Prompts, tool arguments, tool results, plan and review text are excluded from every signal
unless a named, digest-bound, classification-permitted policy admits them per class within byte
bounds; omitted content is a digest plus size, and every signal records the governing policy
digest.
*Rejected:* capture-by-default and scrub-at-export — scrubbing after the fact cannot prove what
never reached the journal, and default-on is one misconfiguration from invisible capture.

### ADR-047 — Sampling applies to export only and never to safety-bearing signals
**Status:** Accepted 2026-08-10. *(Tier F.)*
The journal records everything; the export retention decision is taken when the exporter reads
the journal, so a turn that pauses for days is not lost to an in-memory window. Safety-bearing
signals are never sampled.
*Rejected:* sampling at record time against an in-memory window — a paused/resumed turn outlives
any such window, and dropping safety-bearing evidence would make the durable record lie.

### ADR-048 — One digest-bound OpenAI-compatible model transport
**Status:** Accepted 2026-08-26; **completed by [ADR-051](./adr-051-rubyllm-removed.md).**
*(Tier F.)*
The kernel-owned `ModelClientFactory` is the sole runtime credential resolver and constructs the
`EpisodeModelTransport`. Session, ephemeral, and episode model calls use the same canonical
request/response projection and durable effect boundary. The provider configuration digest binds
provider, model, endpoint, protocol, settings, profile digest, and safety posture — never
credential values. Native Anthropic and Gemini protocols are rejected in this phase; operators
on those families select the `openrouter` provider explicitly. No compatibility alias preserves
the retired `RubyLLMModel`.
*Rejected:* a second SDK adapter — cannot expose the exact wire bytes the durable receipt needs
and keeps two credential/failure/projection paths in production.
**Verified:** 2026-08-29 — `Tamoz::Agent::ModelClientFactory` present; zero `RubyLLMModel`
references (ADR-051 records the full RubyLLM removal).

---

## Standing rejections (size discipline)

These are not decisions of their own but the refusals that keep the framework small; each points
at the ADR that owns the reasoning.

| Rejected | Why | Owned by |
|---|---|---|
| Port LangChain's `Runnable` faithfully | Sixteen methods and async twins to express what duck typing gives free | GOAL non-goals |
| A `Memory` abstraction class family | State must be explicit and injected | ADR-006 |
| Supervisor/swarm/hierarchy classes | Recipes over the engine; shipping topology classes means the engine guesses what agents are | ADR-002-era scope |
| Document loaders in core | LangChain's largest dependency-bloat source; Ruby has good per-format gems | GOAL non-goals |
| `Marshal` as the default serializer | `Marshal.load` on a durable artifact is RCE waiting for a bad day | ADR-020 |
| An async/await API beside the sync one | One API with ordered pool selection; fibers stay optional | ADR-008 |
| Config-dict behaviour dispatch | Stringly-typed action at a distance; use keyword arguments | ADR-006 |
| Building the framework without the agent | The agent is the only honest specification | GOAL |

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — the bar these entries are graded against
- [`RETIRED.md`](./RETIRED.md) — superseded and retired decisions
