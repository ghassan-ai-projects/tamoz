# OpenClaw intelligence and capability: technical report

## Executive finding

OpenClaw's capability advantage is primarily runtime composition. A shared
agent loop can continue after the first model response, call tools, feed results
back into context, steer or accept follow-ups, recover from selected failures,
and expose the work through Telegram, CLI, TUI, cron, memory, plugins, and MCP.

```text
request
  -> session/context
  -> model turn
  -> policy and approval
  -> tool call
  -> bounded observation
  -> next model turn
  -> progress/interruption/continuation
  -> compaction/retry/recovery
  -> terminal result and delivery
```

This is not evidence of generally superior reasoning. The review found strong
plumbing and policy tests, but limited blind real-provider evidence that a model
chooses the right tool or completes a broad mission correctly.

The most important architectural distinction is:

```text
exists -> discoverable -> reachable/authorized -> effectively used -> verified
```

OpenClaw implements these as separate layers. Tamoz should adopt that visibility
while keeping its stronger durable-effect and authority model.

## Request and intelligence lifecycle

### Shared loop

`packages/agent-core/src/agent-loop.ts` is the intelligence kernel. Its main
behavior is:

1. start with user/session context;
2. stream a model turn;
3. inspect the stop reason;
4. if the assistant requested tools, validate and execute them;
5. append tool results as model-visible messages;
6. ingest steering and queued follow-ups;
7. continue until the model stops, a tool terminates, an interrupt arrives, or a
   host policy stops the run.

Key implementation seams:

- loop entry and continuation: `packages/agent-core/src/agent-loop.ts`;
- tool-call gate and execution: `agent-loop.ts` tool dispatch sections;
- deferred tool resolution: `agent-loop.ts` deferred execution sections;
- policy hook and error normalization: `agent-loop.ts` before-tool-call and
  execution sections.

Focused tests cover tool-loop continuation, sequential and parallel calls,
truncated tool calls not being executed, deferred tool hydration, tool
termination, policy blocks, and abort preventing another model turn in
`packages/agent-core/src/agent-loop.test.ts`.

### Outer runtime loop

`src/agents/embedded-agent-runner/run-loop.ts` surrounds the core loop with
operational behavior:

- bounded iterations and wall-clock limits;
- provider/auth-profile rotation and model fallback;
- empty, error, or reasoning-only recovery;
- idle timeout handling;
- context-overflow compaction;
- post-compaction loop detection;
- final settlement and cleanup.

The separation is valuable: the core loop decides whether to continue after an
observation; the outer loop decides whether runtime/provider failure is
retryable. It is not a semantic workflow engine or a mandatory durable planner.

### Planning and routing

OpenClaw's normal planning is model-led and inline. `update_plan`, `create_goal`,
and `get_goal` provide structured product affordances, but the reviewed source
does not establish that every task passes through a separate durable planner.
See `src/agents/tools/update-plan-tool.ts`, `src/agents/openclaw-tools.ts`, and
the goal tool definitions.

Routing is distributed across command handling, channel/session routing, agent
selection, tool policy, delivery, and fallback. The dispatch path is centered on
`src/auto-reply/reply/dispatch-from-config.ts` and the Gateway/agent command
handlers. This is operational routing, not proof of task-aware model selection.

Model selection resolves configured session model, registry, provider, auth
profile, fallback, and per-turn model/thinking changes. See
`src/agents/embedded-agent-runner/model.ts` and its registry/fallback helpers.

## Tool and capability architecture

### Static catalog and factory layers

The core registry is `src/agents/tool-catalog.ts`. The reviewed catalog groups
tools into Files, Runtime, Web, Memory, Sessions, UI, Messaging, Automation,
Nodes, Agents, and Media. It includes tools such as:

- `read`, `write`, `edit`, `apply_patch`;
- `exec`, `process`, `code_execution`;
- `web_search`, `web_fetch`, `x_search`;
- `memory_search`, `memory_get`;
- session inspection, messaging, cron, gateway, goals, plans, approvals,
  delegation, browser, nodes, and media tools.

Tool profiles such as `minimal`, `coding`, `messaging`, and `full` constrain the
surface before final runtime filtering. `src/agents/core-tool-factory-descriptors.ts`
maps tool names to factory families, so the static catalog and factory identity
are not identical.

Plugin tools enter through `src/plugins/registry-types.ts`,
`src/plugins/captured-registration.ts`, and `src/plugins/tools.ts`. Resolution
checks plugin allow/deny policy, manifest availability, credentials, client
capabilities, optional-tool policy, name collisions, factory success, and host
restrictions.

The effective assembly is in `src/agents/agent-tools.ts` and
`src/agents/openclaw-tools.ts`. A tool can exist in source and still be absent
from the model-visible surface.

### Progressive discovery

Tool Search reduces prompt-surface pressure. `tool_search`, `tool_describe`, and
`tool_call` can search a larger catalog, describe a selected schema, and invoke
the normal policy-checked executor. The relevant seams are
`src/agents/tool-search.ts` and the tool-search run-plan/runtime helpers.

Code Mode runs bounded JavaScript over the tool catalog and bridges calls through
the ordinary executor. Its limits include active-run, memory, output, snapshot,
pending-call, wall-clock, and tool-call caps. `restartSafe` rejects side-effecting
namespaces, and the bridge is not automatically retried after dispatch.

This is a capability-discovery optimization, not authority. Search results do
not grant a tool.

### Tool state model

| State | Meaning |
| --- | --- |
| Installed | Source, extension, plugin registration, or manifest exists |
| Discoverable | Catalog/search can return the tool definition |
| Reachable | Runtime config, transport, credentials, client, sandbox, and provider prerequisites resolve |
| Authorized | Final policy, sender, target, workspace, approval, and capability checks permit invocation |
| Effectively used | The model/runtime actually selects it and receives a useful completed result |
| Verified | The result is sufficient to claim the requested outcome |

OpenClaw's source and focused tests strongly cover the first four in selected
paths. Effective use and verification require a composed real-provider mission.

## Capability families and boundaries

### Filesystem and shell

Read/write/edit/apply-patch and exec/process are separate domains. File reads,
search results, directory listings, and shell output are bounded and carry
truncation behavior. Shell targets include host, sandbox, Gateway, and node
paths, with PTY/background/approval/elevated variants.

The source treats timed-out commands as potentially side-effecting and does not
generally replay them. That boundary is safer than a universal retry policy.
Evidence includes `src/agents/sessions/tools/read.ts`, `grep.ts`, `find.ts`,
`bash.ts`, and the shared truncate helper.

### Web and browser

`web_search` is late-bound and enabled only when provider configuration and
credentials are available. `web_fetch` is separate from browser automation and
has bounded response size, redirects, cache behavior, extraction, SSRF checks,
and untrusted external-content metadata. Relevant source is
`src/agents/tools/web-search.ts`, `web-fetch.ts`, and `src/infra/net/fetch-guard.ts`.

The browser extension is a richer action domain: tabs, navigation, snapshots,
extraction, screenshots, downloads, uploads, dialogs, and bounded batches of
actions. Targets can be pinned to a host, sandbox, node, profile, or tab. Stale
target recovery is deliberately narrow and does not broadly replay mutating
actions. Evidence includes `extensions/browser/src/browser-tool.ts`,
`act-policy.ts`, and browser action helpers.

### Database and state

The review found no first-party arbitrary SQL tool in the core agent catalog.
OpenClaw's internal databases support sessions, memory, plugins, and channel
state, but internal persistence is not the same as agent database authority.
Database access can be introduced indirectly through shell, MCP, or a skill.

Regular agents receive a read-only `gateway` tool with `config.get` and
`config.schema.lookup`; configuration output is bounded. Session list/history/
search tools and memory tools provide bounded state inspection with redaction.

### MCP

The MCP client supports stdio, SSE, and Streamable HTTP. Runtime controls include
bounded connection concurrency, catalog and request timeouts, disposal timeout,
failure cooldown, catalog retry, session recycling, requester-scoped connection
resolution, and no replay of a possibly mutating call after an ambiguous session
failure.

Key seams include `src/agents/agent-bundle-mcp-runtime.ts`,
`agent-bundle-mcp-materialize.ts`, `mcp-config-shared.ts`, and
`mcp-connection-resolver.ts`. Catalog diagnostics distinguish not connected,
not listed, and stale states. MCP resources/prompts are separate from ordinary
tools, and materialized tools retain MCP provenance.

OpenClaw also exposes selected built-ins and plugin tools as standalone MCP
servers through `src/mcp/openclaw-tools-serve.ts` and
`src/mcp/plugin-tools-serve.ts`.

MCP descriptions, schemas, prompts, resources, and results are server-controlled
input. They are not trusted because they are structured.

### Messaging and delivery

The `message` tool derives actions from channel capabilities and requires target
resolution for operations where an implicit target would be unsafe. Messaging
has a strong durable queue: stable IDs, insert-once enqueue, producer claims and
fences, attempt IDs, retry budgets, and `unknown_after_send`.

This is evidence that OpenClaw treats outbound messaging as an effect domain,
not just a function call. It is also evidence of operational complexity: an
ambiguous send requires reconciliation instead of blind retry.

## Context, memory, and autonomous continuation

### Sessions and compaction

`src/agents/sessions/sdk.ts` and the session manager persist transcripts,
branches, compaction entries, model/thinking changes, and custom entries. The
context engine has bootstrap, ingest, assemble, after-turn, maintenance, and
compact stages.

Compaction preserves active tasks, progress, decisions, rationale, TODOs,
constraints, commitments, and opaque IDs. It preserves tool-call/result pairs,
retries failed summaries, and has partial/generic fallbacks. Summaries remain
model-generated context, not authoritative evidence.

### Memory

The memory-core extension provides `memory_search` and `memory_get`, indexed
transcript/file search, embeddings/hybrid ranking, visibility filters,
timeouts, degraded-result metadata, recall tracking, and promotion. Project
memory bootstrap and session-memory hooks add persistent context across turns.

Memory can materially improve continuity, but the reviewed evidence does not
prove recall quality in normal real-provider conversations.

### Delegation and scheduling

`sessions_spawn` creates child/subagent or ACP sessions with inherited/narrowed
tool policy, sandbox/workspace restrictions, depth/capacity limits, streamed
completion, and lifecycle recovery. `src/agents/subagent-registry.ts` and its
pending-lifecycle helpers own parent/child bookkeeping.

Cron is a separate autonomous trigger path with isolated sessions, delivery
modes, failure alerts, paced execution, one-shot ownership, and continuation.
Relevant source is `src/cron/isolated-agent.ts`, cron tool/runtime files, and
continuation tests.

Delegation and scheduling explain much of the “agent rather than chatbot” feel,
but they add ownership, concurrency, budget, delivery, retry, and authorization
complexity.

## Self-inspection and self-modification

OpenClaw separates inspection from mutation:

1. read-only config/state inspection;
2. proposal or operation description;
3. exact approval binding;
4. mutation/application;
5. restart/health verification;
6. audit and rollback/quarantine where supported.

The ring-zero `openclaw` tool is host-bound and direct-only. Mutating operations
such as configuration changes, agent creation, Gateway lifecycle, or plugin
installation use host-verified approval and an exact operation hash. The
`skill_workshop` lifecycle supports proposal, revision, evaluation, application,
rejection, quarantine, rollback metadata, and credential scanning.

This is a capability transition, not ordinary chat. A valid config CAS or a
logged actor is not, by itself, proof of authority to widen tools, credentials,
policies, or model routes.

## Guards, recovery, and observability

OpenClaw's relevant guards include:

- layered allow/deny tool policy with deny precedence;
- sender/channel/session-derived capability context;
- optional sandbox with read-only root, dropped capabilities, path checks, and
  network restrictions;
- SSRF and redirect revalidation;
- external-content provenance and injection markers;
- approval binding and stale-answer rejection;
- loop, idle, timeout, output, compaction, retry, and concurrency budgets;
- bounded tool results and channel output;
- provider fallback and failure cooldowns;
- replay-safe versus mutating effect classification;
- durable message queue and ambiguous-send state.

These guards are not equivalent to Tamoz's closed-world capability authority.
OpenClaw's Gateway and plugin model retains a trusted single-operator premise;
sandboxing is not universal and native plugins/MCP remain trusted in-process
components in parts of the system.

The audit ledger is intentionally bounded metadata. It is not a compliance
archive and does not prove that an action did not happen merely because a row is
absent.

## Technical tradeoffs

| OpenClaw choice | Benefit | Cost/risk |
| --- | --- | --- |
| Inline model-led planning | Fast, flexible interaction | Weaker deterministic planning/audit boundary |
| Broad default capability surface | More useful compositions | Larger attack surface and policy burden |
| Tool Search/Code Mode | Lower prompt pressure | Discovery/schema complexity and dynamic trust boundary |
| Background jobs/subagents | Persistent autonomy | Parent/child lifecycle and duplicate-delivery complexity |
| Provider retry/fallback | Availability | Cost, routing, and semantic differences |
| Model-generated compaction | Continuity | Semantic loss and stale-plan risk |
| Host tools and plugins | Low friction | High blast radius under trusted Gateway assumptions |
| Rich channel progress | Strong perceived capability | Connector-specific state and rate-limit machinery |

## What Tamoz should learn

1. Build a shared durable action-observation continuation loop over
   `Session`, `SessionEffects`, and `EffectDispatcher`.
2. Make capability status observable as registered, discoverable, reachable,
   authorized, attempted, effective, completed, and verified.
3. Add progressive tool schemas/search without granting authority through search.
4. Persist observations and tool lifecycle, not only final answers.
5. Treat delegation as durable child work and scheduling as ordinary request
   occurrences.
6. Preserve Tamoz's explicit plan/review path for high-risk work while allowing a
   lighter loop for simple read-only chat.
7. Adopt OpenClaw's bounded recovery and progress UX, but retain Tamoz's effect
   journal, exact identity, unknown outcomes, secret isolation, and approval
   evidence as hard boundaries.

## Evidence limits

This report is based on source, documentation, and inspected tests. No live
OpenClaw provider, Telegram bot, Gateway, browser, database, or MCP server was
run in this pass. Existing tests prove selected plumbing and policy behaviors;
they do not prove general tool-selection quality or broad autonomous success.
