# Tamoz intelligence and capability: current state

## Executive conclusion

Tamoz has a serious durable capability substrate, but it does not currently
present one coherent intelligence runtime.

The three relevant execution models are:

1. **`Session`** — the durable Telegram and durable-CLI path. It performs
   route/plan/review, executes accepted steps, records observations/effects, and
   verifies or repairs. It is safe but primarily plan-driven.
2. **`EpisodeGraph`** — the closest existing match to OpenClaw's
   reason → tool → observation → reason loop. It is durable, but domain-specific
   and wired to the stream worker rather than generic Telegram/durable CLI.
3. **`Runtime`** — an ephemeral plan/repair driver with richer local events, but
   direct model/tool calls outside the durable effect journal.

This fragmentation explains much of the capability perception gap. Tamoz is
not missing all the ingredients; they are split across paths with different
context, event, authority, and recovery semantics.

## Current execution paths

### Telegram and durable CLI

```text
inbound request
  -> admission and profile binding
  -> SQLite request inbox
  -> DurableRunner / Worker
  -> Session graph
  -> SessionEffects / EffectDispatcher
  -> checkpoints and effect receipts
  -> terminal/session view
  -> OutboxDeliverySink / CLI renderer
  -> Telegram delivery or CLI output
```

Telegram's Gateway owns polling, normalization, authentication, admission,
routing, controls, and delivery. It does not construct a model, toolbox, or
session. That boundary is correct and should remain.

Durable CLI commands use the same `Session` execution model. `resume`,
`continue`, `follow-up`, `redirect`, `cancel`, `resolve`, and status/show flows
operate over durable session/request state.

Evidence:

- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb`;
- `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/session.rb`;
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb`;
- `test/comms_gateway_test.rb`;
- `test/agent_cli_test.rb`.

### Ephemeral CLI

```text
tamoz TASK
  -> Agent::Runtime
  -> direct model call
  -> direct toolbox call
  -> local event stream
  -> final answer
```

`Runtime#model_generate` and `Runtime#execute_tool` do not use the durable
`SessionEffects` journal. This path is useful as an explicitly ephemeral mode,
but it must not become Telegram's or durable chat's intelligence backend.

### EpisodeGraph

```text
reason
  -> validate
  -> tool or decision
  -> execute durable effect
  -> rebuild frame with observation
  -> reason again
```

`EpisodeGraph` has the desired action-observation loop, durable effect identity,
typed unknown outcomes, repair, and bounded graph limits. It also carries
domain-specific `ReasoningDocument`, diagnosis, wire, and intent contracts and
is used by the stream worker. It is a valuable control-shape reference, not a
drop-in generic chat engine.

Evidence:

- `gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/episode_nodes.rb`;
- `test/stream_episode_replay_test.rb`;
- `bin/tamoz-stream-worker`.

## What `Session` currently does

The normal durable graph is:

```text
intake
  -> optional route
  -> deliberate
  -> step_gate
  -> step_execute
  -> evaluate
  -> step_gate / deliberate / verify
  -> terminal
```

`SessionDeliberation` builds loop state from phase, observations, allowed tools,
MCP planning surface, conversation context, repair state, and prior failures.
`SessionPlanAttempt` performs a durable model plan call, deterministic structural
review, semantic model review, and bounded acceptance/rejection.

Every model call in the durable path goes through `SessionEffects#model_call`
and `EffectDispatcher`.

`step_gate` selects the next already-planned step and prepares arguments,
approval, and intent. `step_execute` dispatches the committed effect and records
the observation.

The key intelligence limitation is the success path:

```text
successful tool observation
  -> evaluate
  -> next accepted step_gate
```

The model does not normally see every successful observation before choosing the
next action. Re-deliberation occurs mainly after plan completion, failure,
repair, phase transition, or discovery completion. Tamoz therefore behaves more
like a durable reviewed program executor than a continuously replanning worker.

This is an inference from the graph shape, not a live model-quality measurement.

## Current local and external capabilities

### Local tool catalog

`ToolCatalog` exposes a deliberately narrow set:

- read: `read_file`, `list_directory`, `search_text`;
- mutation: `apply_patch`, `create_file`;
- configured check: `run_check`;
- skills: `load_skill`, `read_skill_resource` when an operator-owned snapshot is
  available.

`Toolbox`, `CapabilityBinding`, and `CapabilityHost` apply workspace, path,
mutation, validation, approval, and output boundaries.

Local reads are bounded by file size, UTF-8/NUL checks, directory entries,
candidate files, results, and argument byte limits. Recursive search skips
`.git`, `vendor`, and `node_modules`.

There is no arbitrary shell. `run_check` accepts a configured check name and
exact argv. It does not accept shell interpolation. It strips credential-shaped
environment values, bounds output, runs in the workspace, and terminates the
process group on timeout.

### Capability authority

`Capability::Registry` is closed-world and sealed after construction. Accepted
source families are local, skill epoch, MCP server, and reserved websearch.
`CapabilityBinding` routes validation, preview, approval, safety, execution, and
effect intent through the owning source dispatcher.

The model-visible phase boundary is useful:

- discovery exposes read-only capability names;
- action phases expose the admitted action surface;
- discovery cannot mutate or run checks.

This is a stronger authority foundation than OpenClaw's trusted Gateway model.

### MCP and websearch

MCP is wired into both durable worker and durable CLI paths. `McpSourceBuilder`
compiles a catalog, creates a supervisor, assigns operator risk classification,
and builds source-qualified descriptors. Catalogs are content-addressed and
session-pinned.

Invocation validates arguments and descriptor digests before I/O, bounds catalog,
description, output, nesting, structured fields, connection/request timeouts,
concurrency, stderr, and circuit failures. Read-only transport failures may
retry within a small budget; non-read-only calls become ambiguous after the send
boundary rather than replaying blindly.

Websearch is a reserved MCP source requiring explicit enablement, egress,
provider, and grant configuration. It is not a generic HTTP, browser, or search
capability.

The old manual report recorded an MCP/one-shot gap at an earlier revision.
Current source and focused tests show that durable CLI and worker MCP wiring now
exists. The study does not claim live provider usefulness.

### Browser and database

No first-party browser tool or arbitrary SQL/database tool was found in the
inspected Tamoz capability surface.

SQLite is internal durable state, not agent database authority. Memory retrieval
is an authorized, bounded repository path; it does not expose raw tables, SQL,
or internal schemas to the model.

If database or browser capabilities are added, they must enter as separate
operator-owned capability sources with explicit authority, egress, secrets,
effect class, approval, budgets, provenance, and ambiguity behavior.

## Capability state

| State | Tamoz current behavior | Assessment |
| --- | --- | --- |
| Exists | Local, skill, MCP, and websearch sources are represented in code/catalogs | Strong |
| Discoverable | Phase-filtered names/descriptions are supplied to planning | Present but schema-light |
| Reachable | Local tools and operator-configured MCP are materialized | Strong for configured paths |
| Authorized | Profile, root, skill, MCP, egress, and source bindings are sealed | Strong |
| Effectively used | Focused tests prove scripted dispatch; live model selection is not established | Weak evidence |
| Verified | Receipts, checks, verification, and unknown outcomes exist | Strong for durable paths |

The key missing diagnostic is an explicit capability inventory that says why a
capability is configured, catalogued, materialized, reachable, authorized,
phase-visible, approval-gated, attempted, effective, and verified.

## Context, memory, and compaction

Tamoz has three separate concepts:

1. channel/request transcript;
2. durable session/checkpoint/effect state;
3. long-term verified memory.

Telegram follow-ups carry bounded conversation context in the request payload.
Durable CLI does not automatically have an equivalent conversation transcript
reader. Memory retrieval is authorization-aware and mostly limited to action and
repair contexts.

Memory writes, epochs, provenance, sensitive-record hard zeros, contamination
digests, cited recall, and fabricated-reference refusal are strong. But context-
window compaction, semantic supersession, and structured cross-episode
compression are not implemented as a general capability.

Checkpointing durable state is not the same as compacting a long conversation.
This likely contributes to the impression that Tamoz remembers execution facts
but not the working conversation.

## Background work and self-inspection

The scheduler materializes due occurrences into the ordinary request inbox. It
does not itself execute agent logic or prove delivery. Worker execution applies
current authority, budgets, approvals, and outbox delivery.

Scheduler mechanics are strong: deterministic occurrences, deduplication,
misfire/overlap policy, grant intersection, catch-up, and crash/restart tests.
The product surface is incomplete: users cannot easily see schedule state,
occurrence state, phase, pause reason, restart recovery, or delivery outcome.

Operator CLI/runtime APIs can inspect status, sessions, profiles, config, and
capability sources. There is no general bounded model-facing config/session/state
inspection tool comparable to OpenClaw's read-only Gateway tool.

There is no demonstrated agent-driven package/runtime self-update path. Workspace
changes and repair are bounded, reviewed, verified, and human-gated. Skills and
content cannot grant authority.

## Root causes using the 5 Whys

### Why does Tamoz feel less intelligent?

1. Successful observations usually advance a preaccepted plan.
2. `Session#evaluate` normally returns to `step_gate`, not a model decision.
3. The model therefore sees less intermediate evidence before choosing actions.
4. The best observation loop exists only in a separate domain-specific graph.
5. The user experiences a safe executor, not one continuous adaptive worker.

### Why are tools present but often ineffective?

1. Local/MCP capability existence and authorization are strong.
2. The planning surface is phase-filtered and schema-light.
3. There is no generic progressive search/describe/continue path in Session.
4. Tool selection and effective use are not measured in live missions.
5. Capability breadth therefore does not become capability experience.

### Why does the system feel slow?

1. Legacy routing uses multiple plan/review/execution/verification calls.
2. The user sees only a small portion of those internal transitions.
3. Historical UX runs measured several sequential model calls and occasional
   plan rejection before tool execution.
4. OpenClaw exposes more visible continuation and progress.
5. Tamoz pays governance latency without consistently explaining its value.

### Why is recovery hard to use?

1. Durable recovery exists in request, checkpoint, effect, and outbox records.
2. References and read models are operator-oriented.
3. Telegram lacks rich running/blocked/recovery projection.
4. CLI exposes many separate commands and mode distinctions.
5. Recovery is technically strong but productized poorly.

## Existing strengths to preserve

- operator-pinned authority and profile transitions;
- sealed capability registry and source-owned dispatch;
- durable model/tool effects and receipt replay;
- approval evidence bound to exact plan/argument/preview digests;
- typed unknown outcomes and reconciliation;
- typed secrets rejected from durable and observability surfaces;
- MCP catalog/schema/egress bounds and supervised lifecycle;
- scheduler grant intersection and deterministic occurrences;
- verified memory provenance and contamination controls;
- bounded CLI/Telegram delivery and crash recovery.

## Evidence limits

This is source/test/documentation evidence. Tests were inspected, not executed in
this pass. Most autonomy tests use `ScriptedModel` or fixture endpoints, which
prove plumbing and invariants but not independent model choice. The opt-in real
model stream test proves a real call, not broad intelligence or restart
recovery. No live Telegram, MCP, websearch, browser, database, or composed
real-provider mission was run here.
