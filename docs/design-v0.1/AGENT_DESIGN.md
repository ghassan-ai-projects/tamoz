# `tamoz-agent` — durable execution over RubyLLM

RubyLLM owns provider normalization, messages, tools, chat configuration, and its
`RubyLLM::Agent` class. Tamoz owns durable execution. `tamoz-agent` is the adapter and recipe
layer between them.

It must be possible to remove `tamoz-agent` and use RubyLLM directly when checkpointing,
approval, replay, and graph orchestration are unnecessary.

## 1. Durable ReAct

```ruby
# Illustrative
class CodingAssistant < RubyLLM::Agent
  model "configured-model"
  instructions { Prompt.render(root: inputs.fetch(:root)) }
  tools ReadFile, WriteFile, Bash
end

agent = Tamoz::Agent.react(
  llm: ->(session) { CodingAssistant.new(inputs: { root: session.root }) },
  checkpointer: sqlite,
  store: sqlite.store,
  effects: sqlite.effects,
  policy: Tamoz::App::ToolPolicy.new(roots: [Dir.pwd])
)

agent.ask(
  "Refactor the parser and run tests",
  thread: session_id,
  request_id: input_id
) { |part| render(part) }
```

`llm:` accepts:

- a `RubyLLM::Agent` instance or class;
- a `RubyLLM::Chat`;
- a callable that builds one from session context.

RubyLLM chats are mutable and are never shared across concurrent Tamoz sessions. A factory
is the production default. Passing an instance binds it to one compiled session and
concurrent reuse raises.

The durable graph is explicit. Planning and review are part of the graph, not hidden
instructions:

```text
START → plan → review ── revise ───────────────→ plan
                  │
                  └─ accept → model ── no calls → verify → learn → END
                                │
                                └─ tool calls → tools → compact? → model
```

State:

| Key | Reducer | Purpose |
|---|---|---|
| `plan_versions` | append/idempotent by plan id | goals, assumptions, ordered steps, validation, and rollback |
| `plan_reviews` | append/idempotent by review id | structural and critic decisions bound to a plan digest |
| `message_events` | append/idempotent by event id | auditable conversation log |
| `usage_events` | append/idempotent by effect key | provider-reported tokens and cost |
| `evidence_events` | append/idempotent by evidence id | claims, sources, confidence, and unresolved uncertainty |
| `verification_events` | append/idempotent by check id | expected versus observed outcomes |
| `behavior_version` | one write | prompt, heuristic, routing, policy, and evaluator lineage pinned for resume |
| `cache_epoch` | one write | stable model-request prefix generation |
| `pending_approvals` | append/idempotent | surfaced approval descriptors |
| `remaining_steps` | managed | graceful termination |

The model-visible messages and total usage are deterministic projections. Replayed model
receipts and tool results do not double-count.

### 1.1 Plan-review-execute

Every new task—user initiated, scheduled, delegated, or internally generated—creates at
least a one-step plan before task actions begin. Crash resume may reuse the accepted exact
plan version already in the checkpoint. A plan is a versioned value containing:

- the interpreted goal and explicit definition of done;
- known evidence, assumptions, and unresolved questions;
- ordered steps with dependencies and expected outputs;
- tools/resources, effect classes, budgets, and approval points;
- verification for each material result and rollback/recovery for side effects.

Review always runs in two layers. The structural reviewer deterministically rejects missing
completion, verification, permission, budget, or recovery information. A separate semantic
review pass critiques goal fit, assumptions, ordering, proportionality, risks, and likely
failure modes. Low-risk plans may use the same model in an isolated pass; medium/high-risk
or complex plans route to an independent critic role. Human review is requested only when
policy requires approval or unresolved intent could materially change the outcome. A
one-step read-only task still has a plan and both review records, but need not create
user-visible ceremony.

When supplied evidence is insufficient for an honest action plan, Tamoz uses two reviewed
stages rather than guessing:

1. a **discovery plan** authorizes only locally classified read-only capabilities within
   declared roots/sources, query and byte limits, time/cost budgets, sensitive-data rules,
   and an evidence objective;
2. the discovery result becomes cited evidence for a new **action plan**, whose review
   authorizes mutation, delegation, or external effects.

A discovery plan cannot rely on a remote server annotation, skill text, or model assertion
that an operation is read-only. It cannot execute scripts, obtain credentials beyond its
declared evidence sources, delegate work, mutate application state, or authorize a later
action. If discovery crosses a declared boundary, it stops and requires a new reviewed
version. Deterministic metadata already supplied by the caller may be normalized before
review; acquiring application evidence may not.

An accepted review binds `plan_id`, plan kind (`discovery` or `action`), canonical plan
digest, reviewer/policy versions, risk class, and decision (`accept`, `revise`, or
`needs_input`). Every task-action node requires that binding. Before any accepted plan,
only planning/review model calls, necessary clarification, and deterministic normalization
of caller-supplied metadata are allowed. An accepted discovery plan opens only its bounded
read-only evidence capabilities; mutation, delegation, and external effects remain blocked
until an exact action plan is accepted. Any material change to goal, steps, tools, resources,
effect class, budget, or verification creates a new plan version and invalidates the prior
review.

Execution is incremental. After each step the agent compares observed evidence with the
plan. A mismatch, new risk, failed assumption, or budget change stops scheduling at the next
safe barrier and returns to plan/review. It never edits a plan in place to make the trace
appear successful.

## 2. RubyLLM boundary

Tamoz drives one model generation at a time. It does not call a RubyLLM method that hides the
whole tool loop behind one opaque operation.

The adapter:

1. materializes the current epoch's model request;
2. records its digest and effect identity;
3. invokes the public RubyLLM chat/agent API once;
4. streams chunks through Tamoz's bounded sink;
5. captures the final RubyLLM message and usage;
6. converts it to the registered durable codec without dropping unknown fields;
7. returns message and usage events to the graph barrier.

If RubyLLM lacks a stable public single-generation seam, M4 stops and either contributes
that seam upstream or narrows Tamoz's integration. Reaching into RubyLLM internals is not an
acceptable foundation.

Provider and model counts are intentionally absent from this design because they change
independently of Tamoz.

## 3. Tool contract and ordering

Tools remain RubyLLM tools. Tamoz adds policy metadata:

```ruby
class WriteFile < RubyLLM::Tool
  tamoz_effect :idempotent
  tamoz_resources { |path:, **| [Tamoz::Resource.file(path)] }
  tamoz_timeout 30
end
```

ToolNode behavior:

| Concern | Contract |
|---|---|
| Validation | schema validation before policy or execution |
| Policy | canonical tool name, normalized args, resolved resources, session identity |
| Approval | after validation/resource resolution, before effect preparation |
| Effect safety | every call declares read-only, idempotent, transactional, reconcilable, or unsafe |
| Parallelism | only calls whose resource locks and policy permit it run concurrently |
| Model-facing order | results always follow the assistant's original tool-call order |
| Live progress | may follow completion order and carries tool-call id |
| Errors | only declared recoverable categories become typed tool results; ambiguous timeout becomes effect-unknown |
| Output | bounded inline representation plus protected spill reference |
| Cancellation | cooperative; late state cannot commit, effect outcome still reconciles |

Parallelism is opt-in by effect/resource safety, not an unconditional default. Two writes to
the same path, database row, or shell workspace serialize even if the model requested them
together.

Spill files are content-addressed, mode `0600`, confined to a session-owned directory, and
subject to quota and retention. Streams/logs contain an opaque reference, never an
unredacted path or contents unless content capture is enabled.

## 4. Effects and crash semantics

Tool execution is:

```text
validate → authorize → approve → prepare effect → execute → record receipt → return event
```

The effect key derives from thread, namespace, execution, stable logical activation id,
tool-call index, and operation. It excludes attempt id and resume checkpoint. For idempotent
targets, Tamoz passes the same key on every attempt. For filesystem writes, the tool uses
atomic replace plus a content digest. For a remote API, its native idempotency header is
preferred.

An unsafe tool is allowed only under a policy that supplies a reconciler or accepts human
resolution. After an ambiguous crash it emits `effect_unknown`, pauses, and presents:

- operation and canonical resource;
- approval and execution timestamps;
- request digest and any external id;
- safe reconciliation actions.

It never repeats automatically.

A timeout is a model-facing timeout only when dispatch did not occur or the target confirms
cancellation. If Tamoz cannot know whether an effect completed, timeout produces `:unknown`
under the same rules as process crash.

Model calls use the same journal semantics. When a provider offers no idempotency/result
lookup, an ambiguous crash may incur a repeated call and charge. This limitation is exposed
in metrics and documentation.

## 5. Approval and authorization

Approval is an interrupt, but approval is not authorization.

The non-bypassable policy wrapper runs outside user hooks:

1. canonicalize and validate arguments;
2. resolve resources without following an unapproved symlink escape;
3. apply deny rules and least-privilege roots;
4. determine approval requirement;
5. ask the surface;
6. revalidate resource identity immediately before execution;
7. execute through the effect wrapper.

An approval record binds tool, normalized argument digest, resources, effect key, policy
version, user/session identity, and expiry. Editing arguments creates a new decision.
`approve_always` is scoped to a policy-defined tool/resource pattern and session; it is
never a process-global bypass.

Hooks may narrow or veto. They cannot widen permissions or bypass validation, approval, or
effect journaling.

## 6. Model routing, budgets, and fallback

Routing is a typed policy:

```ruby
router = Tamoz::Agent::Router.new(
  default: :primary,
  routes: { title: :cheap, subagent: :balanced },
  fallbacks: { overload: [:secondary] },
  budget: { cost: 5.00, input_tokens: 500_000, output_tokens: 100_000 }
)
```

Symbolic model roles resolve through application configuration. Checkpoints persist both the
role and resolved provider/model identifier so replay is auditable.

Fallback is limited to categories known to be safe (for example overload before any output).
A partial streamed response is not silently sent to a different model. The adapter records
whether a provider request was accepted, streamed, completed, or ambiguous.

Budget checks occur before scheduling and after provider-reported usage. Provider token
counts are authoritative when present; estimates are marked estimates. Near the limit, the
agent compacts or produces a final summary rather than starting another tool loop.

## 7. Prompt-cache epochs

The invariant is request-prefix stability, not a promise that a provider will grant a cache
hit.

At epoch creation, the agent persists:

- canonical system messages;
- canonical tool schemas in stable order;
- model/provider settings that affect the request prefix;
- skill-catalog digest and descriptions;
- serializer/canonicalization version;
- reason the epoch began.

Every model call recomputes the digest and fails before network I/O if it differs without an
epoch transition. Dynamic date/time or runtime facts belong in user/turn context, not the
stable system prefix.

Epoch changes are explicit for compaction, tool schema changes, model-setting changes, or
skill catalog changes. The framework reports cache reads/writes from provider usage when
available; it never infers a hit from digest stability alone.

## 8. Compaction

Compaction appends events; it does not rewrite durable history.

```ruby
Tamoz::Agent::Compactor.new(
  trigger: ->(view) { view.context_tokens > view.limit * 0.75 },
  keep_recent: 20,
  preserve: %i[user_corrections unresolved_effects tool_errors pinned],
  summarizer: :cheap
)
```

The compaction node:

- selects a contiguous closed range of message-event ids;
- generates a summary with source ids and a content digest;
- appends `CompactionApplied`;
- starts a new cache epoch whose projection uses the summary plus preserved/recent events;
- leaves the pre-compaction checkpoint available for fork/recovery.

Compaction never hides unresolved approvals/effects, policy decisions, user corrections, or
tool errors. A summary is untrusted model output and cannot grant permissions or create
facts outside its cited source range.

## 9. Subagents

A subagent is a graph recipe with:

- its own graph version and state namespace;
- an explicit persistence mode (`:invocation`, `:thread`, or `:none`);
- a tool subset and policy no broader than its parent;
- step, token, cost, concurrency, and wall-clock budgets;
- a typed return projection.

The default is per-invocation state. Long-lived subagent memory is opt-in because it changes
privacy, prompt-cache, and surprise costs.

Delegation is an effect-bearing tool call only when it crosses a process or sends external
messages. In-process graph delegation remains ordinary durable scheduling. Fan-out results
commit in declared subagent-key order.

## 10. Skills

Tamoz implements the open Agent Skills `SKILL.md` format with progressive discovery, load,
resource-read, and separately authorized script execution. Each skill is compiled into a
source-qualified, content-addressed immutable record and pinned by catalog/cache epoch.

Skill instructions and resources are attributed untrusted content. Loading never grants a
tool, root, credential, environment value, network route, or policy exception.
`allowed-tools` is only the author's requested maximum; effective authority is the
intersection of agent, task/plan, parent/schedule, and skill limits.

Same-name collisions across sources never shadow silently. File changes and installs
produce a candidate next epoch, and resume requires the exact tree digest. Catalog size,
resource bytes, path resolution, scripts, dependencies, installation, self-proposed
changes, and evaluation are specified in [SKILLS_DESIGN.md](SKILLS_DESIGN.md).

## 11. MCP

`tamoz-mcp` is an accepted post-v0.1 edge package built on the official `mcp` Ruby SDK.
MCP tools, resources, resource templates, and prompts enter the same locally governed
capability catalog under source-qualified identities. Protocol schemas and metadata are
validated and snapshotted, but remote annotations never define trust, effect safety,
authorization, or approval.

Elicitation maps to a durable interrupt tied to the originating call. Experimental remote
tasks map to effect handles. OAuth credentials remain in a credential provider, stdio
servers run under explicit process/sandbox policy, and outputs are bounded attributed
untrusted content. A list change or failed source creates a candidate next epoch rather
than mutating the current turn. Protocol/version profiles, supervision, retries,
reconciliation, server-export mode, and security gates are in
[MCP_DESIGN.md](MCP_DESIGN.md).

## 12. Bounded self-improvement

Self-improvement is a controlled promotion pipeline, not live prompt or code mutation:

```text
trajectory → diagnose → candidate → offline evaluation → policy gate → promote → monitor
                                  └──────── reject/quarantine ← regression ────────┘
```

The learner may propose:

- user-approved memories and preference corrections;
- planning, routing, tool-selection, compaction, or verification heuristics;
- prompt, skill, and policy revisions;
- code/configuration changes as reviewable patches.

Each candidate records provenance, training/evaluation data boundaries, base and candidate
artifact digests, predicted benefit, affected capabilities, risk class, evaluation results,
approver, activation scope, and rollback target. Evaluation uses a pinned holdout corpus
that excludes the trajectory which generated the candidate. Promotion requires improvement
over the current baseline without violating safety, correctness, privacy, latency, or cost
budgets.

The agent may automatically activate only bounded, reversible changes within a
pre-authorized policy—for example a routing weight or planning heuristic with no capability
change. Prompt hierarchy, tool access, filesystem/network roots, credentials, approval
rules, security policy, executable code, and evaluator definitions always require explicit
human approval. Generated content can propose but cannot approve its own promotion.

Every activation starts a behavior version, supports rollback, and is monitored against the
same gates. It also starts a cache epoch when the request prefix changes; unrelated routing
or operational tuning must not discard a valid cache. Regression or missing evidence
automatically disables the candidate. Raw trajectories remain protected artifacts;
promotion never treats model output as trusted policy.

An in-flight execution remains pinned to its checkpointed `behavior_version`. A later
external turn may adopt the current promoted version only through an explicit
`BehaviorTransition` at the turn boundary; the transition records old/new versions, reason,
promotion record, and any cache-epoch change. Rollback uses the same mechanism.

## 13. Smart action policy

“Acts smartly” is an operating contract, not a model-quality guarantee. For each step the
agent:

1. gathers the minimum evidence needed to reduce consequential uncertainty;
2. separates observations, inferences, assumptions, and unknowns;
3. chooses the simplest action with the best expected outcome under risk, cost, and time
   budgets;
4. uses specialized tools or delegated agents only when they add measurable value;
5. asks rather than guesses when uncertainty could materially change or harm the result;
6. verifies material outputs with an independent signal when one exists;
7. stops when the definition of done is met, rather than continuing activity for its own
   sake;
8. records failures and corrections as learning evidence without automatically changing
   behavior.

Confidence never grants permission. Model self-critique never substitutes for deterministic
validation, tool authorization, tests, or human approval. Quality is measured by task
success, unnecessary-action rate, correction rate, verification coverage, calibrated
uncertainty, safety violations, latency, and cost.

## 14. Memory and self-healing recipes

Tamoz Agent memory is **Experience → Knowledge → Wisdom**. Working context remains graph
state. Admission, authorized retrieval, consolidation, contradiction, forgetting,
correction, deletion, and evaluated promotion follow
[MEMORY_DESIGN.md](MEMORY_DESIGN.md). Memory never grants capability or approval.

Self-healing is a separate bounded remediation graph over typed failures:

```text
classify → plan/review → preflight → remediate → verify
                                         ├─ uncertain → reconcile/escalate
                                         └─ failed → compensate/circuit/escalate
```

It reuses plans, authorization, effects, checkpoints, and evaluation rather than adding a
catch-all retry layer. Rule contracts, circuits, fault injection, and non-goals are in
[SELF_HEALING_DESIGN.md](SELF_HEALING_DESIGN.md). A healing outcome may produce Experience
and improvement candidates, but it cannot edit Knowledge, Wisdom, code, policy, or its own
rule while recovering.

## 15. Scheduled tasks

Time is an external input source. `tamoz-scheduler` calculates and durably claims
content-addressed occurrences, then delivers a stable request id into the existing request
ledger. The normal agent lifecycle still plans, reviews, executes, verifies, and records
the task.

A schedule pins its payload, maximum capability grant, behavior adoption, budgets,
approval/escalation, and delivery policy. Runtime authority is the intersection with
current policy, so delayed work cannot retain revoked access. Misfire, overlap, timezone,
DST, jitter, crash, edit, and cancellation semantics are explicit and auditable. See
[SCHEDULER_DESIGN.md](SCHEDULER_DESIGN.md).

## 16. Streaming Situations and physical intent

`tamoz-agent` never subscribes to an unbounded source. `tamoz-stream` admits a bounded,
content-addressed `SituationSnapshot` and derives a stable request id. The ordinary
plan/review/execute/verify graph binds its accepted plan to that snapshot digest.

The agent returns a typed `Decision` and zero or more `ActionIntent`s. It does not receive
effector credentials. A separate deterministic action boundary reloads current
Situation/device state and checks freshness, scope, bounds, quotas, approval, expiry,
external interlocks, and effect reconciliation before dispatch. A corrected Situation can
supersede the episode; its late result cannot act.

This boundary lets Tamoz Agent supervise equipment and environments without making the LLM
a hard real-time or functional-safety controller. See
[STREAMING_INPUT_DESIGN.md](STREAMING_INPUT_DESIGN.md).

## 17. Hooks

Hooks exist for application policy and observation:

```ruby
agent.before_model { |request, context| ... }
agent.before_tool_call { |call, context| ... }  # veto or narrow only
agent.after_tool_call { |result, context| ... } # redact or narrow only
```

Hook order is registration order and is frozen when the agent compiles. Hook output is
validated. Hooks cannot bypass the outer authorization/effect wrapper or mutate committed
state. Behavior required for correctness is a node or policy object, not a hook.

## 18. Non-responsibilities

- no provider implementation or model registry;
- no prompt library or bundled personality;
- no topology class zoo;
- no general-purpose model-training platform;
- no channel adapters or unbounded stream engine inside `tamoz-agent`;
- no direct actuator access, hard real-time loop, or certified safety function;
- no plugin API in v0.1;
- no guarantee that arbitrary third-party tools are idempotent or cancellable.
