# Tamoz intelligence and capability: target architecture

## Design decision

Make durable `Session` the sole intelligence kernel for Telegram and durable
CLI. Add bounded observation-continuation to the existing graph, borrowing the
control shape of `EpisodeGraph`, but reusing Tamoz's authority, capability,
effect, checkpoint, approval, and delivery seams.

Do not route Telegram to `Runtime`. Do not create another chat runtime. Do not
mount `EpisodeGraph` directly into generic chat because its reasoning and
diagnosis contracts are domain-specific.

## Target intelligence loop

```text
admit and bind authority
  -> route to interaction mode
  -> choose one bounded next action
  -> durable model effect
  -> validate against sealed capability set
  -> approval/effect gate
  -> durable tool effect
  -> bounded observation with provenance
  -> verify and classify
  -> continue / repair / replan / wait / stop
  -> checkpoint and project lifecycle
```

The loop should have two modes:

### Adaptive read-only mode

For repository inspection, state inspection, search, and other read-only tasks:

1. model chooses one bounded action;
2. action runs through `SessionEffects` and `EffectDispatcher`;
3. observation is appended with effect identity, source, truncation, and result
   classification;
4. model sees the observation and chooses the next action or final answer;
5. graph limits, budgets, repeated signatures, cancellation, and idle breakers
   stop the loop.

This is the safest first slice because read-only actions do not change external
state, while still giving Tamoz the OpenClaw-like inspect → act → observe →
continue behavior.

### Governed action mode

If the model requests mutation, external messaging, configuration, browser
interaction, database write, or another non-read-only effect:

1. leave the adaptive read-only loop;
2. construct an explicit bounded action plan;
3. run structural and semantic review;
4. bind exact capability, arguments, authority, revision, and effect identity;
5. request evidence-bound approval when required;
6. execute through the durable effect journal;
7. verify the result or preserve `unknown` and block.

This preserves Tamoz's stronger safety model instead of treating a model-selected
tool call as sufficient authority.

## Existing seam map

| Target capability | Extend | Do not create |
| --- | --- | --- |
| Adaptive continuation | `Session`, `SessionLifecycle`, `SessionSteps`, `SessionEvidence` | A second model/tool runner |
| Model calls | `SessionEffects#model_call`, `EffectDispatcher` | Raw model calls inside graph nodes |
| Tool calls | `SessionEffects#dispatch`, `CapabilityBinding`, `CapabilityHost` | Generic tool-name bypass |
| Observation persistence | session checkpoint/effect journal, `SessionView` | In-memory trajectory authority |
| Planning/review | `SessionDeliberation`, `SessionPlanAttempt` | Removing review from mutation paths |
| Read-only discovery | `CapabilityBinding#names(:discovery)`, MCP catalog snapshots | Search that grants capability |
| Tool schema projection | `ToolCatalog`, MCP pinned catalog/descriptors | Unbounded remote schemas in prompts |
| Status | `SessionView`, request inbox, MCP supervisor, outbox | Status that materializes network state implicitly |
| Channel progress | `Worker#notify_sink`, `OutboxDeliverySink`, CLI rendering | Direct Telegram calls from the agent |
| Scheduling | scheduler materialization and ordinary request inbox | A parallel timer-driven agent loop |
| Delegation | durable child requests and existing worker leases | In-memory child registry as authority |
| Memory/context | `SessionPlanningContext`, memory repository, new compaction seam | Treating summaries as evidence |
| Self-modification | profile/skill preview/import/activate and improvement promotion | Model-controlled active authority mutation |

## Durable event and observation contract

Every meaningful action-observation transition should carry stable identity:

```json
{
  "schema": 1,
  "kind": "model_turn|capability_state|tool_started|tool_result|approval|checkpoint|terminal",
  "thread_id": "...",
  "request_id": "...",
  "execution_id": "...",
  "iteration": 0,
  "effect_key": "...",
  "capability": "source-qualified-name",
  "phase": "discovery|inspect|plan|act|verify|recover",
  "task_state": "running",
  "effect_state": "succeeded|failed|unknown|waiting|reused",
  "result": {
    "summary": "bounded safe summary",
    "bytes": 0,
    "truncated": false,
    "provenance": "workspace|mcp:server|websearch:server"
  },
  "next_action": "...",
  "emitted_at": "..."
}
```

This is a target contract. It should preserve existing stream/effect identity,
not turn model prose into authoritative state.

The continuation iteration must be part of effect identity. The current fixed
`call_index` assumption is safe only while one effect exists per step. Adaptive
continuation and compound capabilities need a durable per-effect/sub-operation
identity to prevent receipt collisions.

## Capability inventory and discovery

Add a read-only capability inventory derived from existing registries and
snapshots. It should expose:

```text
declared
configured
catalogued
materialized
reachable
authorized
phase_visible
approval_required
effect_class
schema_digest
reason_unavailable
```

Do not expose secrets. Do not connect to MCP or start processes merely to answer
an ordinary status request.

Use three explicit operations:

1. **peek** — config/catalog metadata only; no process spawn or network;
2. **materialize** — explicit bounded catalog handshake with timeout and health;
3. **invoke** — ordinary capability/effect path with approval and receipts.

If materialization fails, return a structured unavailable reason rather than
aborting the entire status document. Examples:

- disabled by configuration;
- command invalid;
- catalog handshake failed;
- catalog digest changed;
- circuit open;
- not visible in current phase;
- approval required;
- source reachable but not admitted.

Progressive schema discovery should return bounded local validator schemas and
pinned MCP schemas. Search/describe must never grant authority.

## Self-inspection and self-modification

### Read-only inspection

Expose a bounded model-facing inspection capability only for safe state:

- current session/request/task state;
- capability inventory and health;
- schedule/occurrence status;
- bounded profile/config schema and redacted values;
- checkpoint/effect/approval status;
- recent durable observations and recovery handles.

Inspection must be caller-bound, redacted, bounded, and side-effect free. It
must not reveal credentials, internal arbitrary SQLite, or unrestricted logs.

### Mutation and self-update

Config, profile, skill, routing, package, plugin, and MCP changes are authority
transitions. Use this lifecycle:

```text
inspect
  -> propose immutable candidate
  -> validate schema/policy/digest
  -> explicit human approval
  -> durable apply effect
  -> restart/health verification
  -> activate next turn or rollback candidate
```

Workspace content, skills, MCP descriptions, and model output cannot widen
authority. Candidate promotion remains human-gated and provenance-bound.

Package/runtime self-update is a separate higher-risk capability and should not
be part of the first intelligence slice.

## Context, memory, and compaction

Unify the user-facing context model while keeping three kinds of state distinct:

- transcript/context: what the current conversation can see;
- execution evidence: what the durable system knows happened;
- long-term memory: verified, authorized, provenance-bound prior experience.

Add a compaction seam to `SessionPlanningContext` that:

- preserves goal, constraints, plan/effect IDs, approvals, decisions, pending
  work, and next action;
- externalizes large tool results behind bounded references;
- keeps effect receipts and verification facts outside model-generated summaries;
- records compaction as a durable checkpoint/effect;
- supports retry and fallback when a summary fails;
- never treats a summary as new evidence or authority.

Telegram and durable CLI should use the same context/session identity. Memory
recall should remain read-only, cited, bounded, and unable to grant permissions.

## Delegation and background work

Represent a child task as a durable request/occurrence with:

- parent request and owner;
- narrowed capability/profile snapshot;
- depth and concurrency budget;
- independent effect identities;
- progress and terminal receipts;
- explicit completion adoption into the parent;
- restart/recovery and delivery state.

Scheduled work should materialize into the same request inbox and use the same
Session, approval, effect, verification, and outbox path. The model may propose a
schedule, but operator-owned schedule templates and current authority determine
what can actually execute.

## Safety invariants

1. Tool search/discovery never grants capability.
2. Every new capability declares source, schema digest, effect class, approval,
   egress, secret, budget, retry, and reconciliation semantics.
3. Unknown or unclassified capability descriptors fail closed.
4. MCP descriptions/results and web/browser content are untrusted data, not
   instructions or authority.
5. Every model/tool/delegation/config operation uses `EffectDispatcher` or an
   equally durable effect seam.
6. Effect identity includes request, execution, capability, arguments, catalog/
   authority revision, and durable iteration/sub-operation identity.
7. Sent non-idempotent operations that lose their response become `unknown` and
   are reconciled, never blindly replayed.
8. Approval binds actor, request, plan/step, effect, argument/preview digest,
   authority revision, and expiry; unknown effects fail closed.
9. Secrets are typed and rejected from prompts, receipts, telemetry, and state.
10. Self-inspection is read-only; self-modification is candidate/approval/apply/
    verify/rollback state.
11. Cancellation and restart preserve requested, observed, terminal, and unknown
    distinctions.
12. Task state, effect state, and delivery state remain separate.

## Staged implementation plan

### Stage 0 — authority and identity gates

- classify every current and future capability by effect class;
- make unknown capability safety fail closed;
- fix compound effect identity before adding adaptive loops;
- fence MCP descriptions/results as untrusted data;
- verify egress and secret boundaries for every new transport;
- add regression tests for these invariants.

### Stage 1 — capability visibility

- add `peek`, `materialize`, and `status` capability diagnostics;
- expose configured/reachable/authorized/effective distinctions;
- make local/MCP schemas available through bounded discovery;
- return structured unavailability reasons;
- keep discovery read-only and non-connecting by default.

### Stage 2 — adaptive read-only continuation

- add a new durable graph branch/version for one-action observation turns;
- route model/tool calls through `SessionEffects`;
- persist observations and iteration identity;
- add loop, idle, budget, repeated-action, cancellation, and compaction guards;
- stop before mutation and hand off to reviewed action mode.

### Stage 3 — unified context and lifecycle projection

- add durable compaction/checkpoint projection;
- align Telegram and CLI context/session identity;
- project model/tool/approval/checkpoint/terminal events through existing sink;
- make status show task, effect, capability, and delivery state separately.

### Stage 4 — governed expansion

- add safe database/browser/remote capabilities only as separate descriptors;
- add durable child tasks and user-visible scheduling;
- add candidate-only profile/skill/config proposals;
- add operator recovery and reconciliation UX;
- do not add package/runtime self-update until separate gates pass.

### Stage 5 — measured intelligence

- run real-provider missions with tool selection not scripted;
- compare common-subset and native-envelope tracks;
- measure tool choice, outcome, safety, recovery, cost, and latency;
- run the same canonical missions through Telegram and CLI;
- publish only statistically supported claims.

## Non-goals

- a general arbitrary shell tool;
- raw SQL against internal Tamoz state;
- unrestricted browser or network access;
- model-controlled policy/profile/secret mutation;
- in-process untrusted plugin/MCP execution;
- a second runtime parallel to `Session`;
- claiming intelligence improvement from fixture tests or tool counts.
