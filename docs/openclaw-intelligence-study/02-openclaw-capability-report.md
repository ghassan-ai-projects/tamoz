# OpenClaw capability: product and user report

## The user-visible model

OpenClaw feels less like a chatbot waiting for an answer and more like a worker
that can inspect, decide, act, verify, continue, and report back.

The user asks for an outcome:

> “Find out what happened, change what is needed, and tell me when it is done.”

The system can then search, inspect files or state, call a tool, observe the
result, try the next action, ask for approval, recover from a failure, or keep
working in the background. That is the product meaning of “intelligent” here:
the system closes more of the distance between intention and verified outcome.

It is not proof that the underlying model reasons better than Tamoz's model.

## Why it feels more capable

### 1. It keeps going after the first response

The core loop feeds tool results back to the model and continues. The user does
not need to manually copy a tool result into a second prompt. Follow-ups and
steering can enter the same active run.

This creates initiative: the user states the goal, while the agent chooses the
next observable action within its authority.

### 2. It can inspect and act in the same conversation

The visible capability surface spans files, shell/processes, web, browser,
memory, sessions, messaging, scheduling, nodes, goals, plans, approvals,
delegation, plugins, and MCP. A user can stay in Telegram or CLI while the
agent crosses these domains.

The breadth matters because useful work often crosses boundaries. “Investigate
the issue” may require reading a file, searching the web, checking state,
calling a service, editing a config, running a test, and reporting the result.

### 3. It discovers tools instead of dumping every schema into context

Tool Search, tool description, and Code Mode let the runtime keep a large
catalog while exposing only the relevant subset. This lowers prompt pressure
and makes a broad tool surface more usable.

The product lesson is progressive discovery, not unrestricted authority.

### 4. It shows work while work is happening

Telegram and TUI can show typing, draft output, tool activity, plans,
approvals, progress, interruptions, and final delivery. Visible intermediate
state makes a slow task feel alive and gives the user evidence that the agent is
doing something useful.

This is separate from model intelligence. Better lifecycle communication can
make the same model feel substantially more capable.

### 5. It remembers the working narrative

Sessions, transcript branches, memory search, project memory, and compaction
preserve enough context for the agent to continue. Compaction attempts to retain
active tasks, decisions, constraints, TODOs, and opaque identifiers.

The user experiences this as continuity. The caveat is important: a generated
summary can omit or distort facts. Memory and compaction are context, not proof.

### 6. It can work while the user is away

Cron, isolated runs, subagents, goals, and continuation allow background work.
This changes the product from “ask and wait” to “delegate and receive a result.”

The cost is a larger state machine: ownership, scheduling, retries, delivery,
approvals, duplicate prevention, and recovery.

### 7. It recovers instead of abandoning the conversation

Provider fallback, bounded retry, compaction recovery, loop detection, approval
waiting, restart recovery, MCP cooldowns, and ambiguous delivery states allow the
system to explain or repair many failures.

The user sees persistence and competence, but the system must remain honest about
unknown effects and incomplete work.

## Capability journeys

| Journey | What the user experiences | OpenClaw pattern | Important caveat |
| --- | --- | --- | --- |
| Ask a factual question | Answer plus web evidence when freshness matters | Model chooses search/fetch and continues | Real tool selection quality is not broadly proven |
| Investigate a repository | Read, search, inspect, test, summarize | Filesystem/search/shell loop | Shell is a high-authority boundary |
| Change a project | Proposed edit, execution, result, repair | Write/edit/exec with bounded output | Approval and effect durability vary by tool |
| Inspect config/state | Read-only state and schema access | Gateway/session/state tools | Internal database is not a general SQL tool |
| Update the system | Proposal, approval, mutation, restart/health | Ring-zero config/tool/skill workflows | Must be treated as an authority transition |
| Use an external system | MCP/browser/message action | Dynamic discovery and adapters | Remote schemas/results are untrusted input |
| Wait for long work | Progress, approval, background completion | Cron/subagent/continuation | More lifecycle and duplicate-effect risk |
| Recover from failure | Retry, resume, reconcile, or clear next action | Outer loop and durable delivery | Unknown is not success or safe retry |

## What “self-aware” means in practice

OpenClaw can inspect parts of its own operating environment through bounded
tools: configuration reads, schema lookup, session/history/search, tool
availability diagnostics, Gateway status, memory, and runtime diagnostics.

That does not mean the model has privileged omniscience. It sees only the
state exposed through reachable tools and policy. A tool catalog can be stale; a
provider can be unavailable; a session query can be bounded; and an absent audit
row is not proof that an external side effect did not happen.

Self-modification is a different class of capability. Config writes, Gateway
lifecycle changes, plugin installation, and skill changes require more authority
than inspection. OpenClaw separates proposal, exact approval, application,
restart/verification, and rollback/quarantine in important paths.

Tamoz should adopt that user experience while making the authority transition
even more explicit and durable.

## What OpenClaw proves and does not prove

### It proves strongly in static/test evidence

- broad tool and plugin catalogs;
- a shared model-tool-observation loop;
- tool filtering and policy layers;
- bounded outputs and timeouts;
- session/memory/compaction machinery;
- MCP transport/discovery/recovery plumbing;
- approval and restart state machines in selected paths;
- Telegram and TUI lifecycle projection seams;
- background scheduling and delegation infrastructure.

### It does not prove in this study

- that its model is generally smarter than Tamoz's model;
- that a real model consistently chooses the correct tool;
- that memory improves normal conversation quality;
- that a multi-tool mission succeeds through every channel;
- that every external side effect is replay-safe across crash boundaries;
- that a self-update is correctly judged, approved, applied, rolled back, and
  verified by a real model;
- that Telegram, MCP, browser, and provider behavior is correct in a live
  deployment.

The supported comparison is:

> OpenClaw exposes a broader effective autonomy envelope: more reachable tools,
> more persistent runtime state, more background execution, more recovery, and
> more polished channel integration.

A stronger intelligence claim requires a controlled benchmark with matched
model/provider, task wording, permissions, context budget, timeout, and cost.
Measure task completion, tool-selection correctness, unauthorized actions,
side-effect correctness, recovery, duplicate effects, latency, token cost, and
final-result quality.

## Product principles for Tamoz

1. **Ask for outcomes, not tool choreography.**
2. **Keep the agent acting after observations, but stop at durable checkpoints.**
3. **Make capability visibility progressive and searchable.**
4. **Show the user what the agent is doing and what it needs next.**
5. **Treat memory and summaries as context, not evidence or authority.**
6. **Make self-inspection easy; make self-modification explicit and reviewable.**
7. **Treat every external system as a separate effect domain.**
8. **Make retry, unknown, approval, and recovery understandable.**
9. **Measure effective outcomes rather than counting tools.**

## The product target

Tamoz should feel like a capable operator with a durable work ledger:

```text
understand goal
  -> inspect available capabilities
  -> choose a bounded next action
  -> ask approval if authority changes
  -> execute through a durable effect
  -> observe and verify
  -> continue or stop with a reason
  -> show progress and recovery handles
```

The target is not to copy OpenClaw's broad host access. Tamoz's advantage should
be “capable without losing the receipt”: every meaningful model/tool action is
authorized, journaled, recoverable, and explainable.
