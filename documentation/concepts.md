# Tamoz concepts

Use this guide to look up the terms you meet while using Tamoz. Start with the agent concepts;
read the framework and operations sections when you build graphs or run durable workers.
There is no fixed number of concepts to learn.

For a walkthrough of how these pieces fit together, read the [core mental model](overview/concepts.md).
For exact Ruby names and methods, use the [API reference](reference/public-api.md).

## Using the agent

| Concept | Meaning | When you need it |
|---|---|---|
| Agent | The application that uses a model and tools to work on a task. Tamoz Agent is the reference application built on the Tamoz framework. | Start with the [quickstart](getting-started/quickstart.md). |
| Turn | One unit of work on a request. It may finish, pause for input, or stop with an unresolved outcome. | When asking for work or reading its result. See [sessions](getting-started/sessions.md). |
| Thread | The durable history that groups related turns. It can continue across process restarts. | When keeping a conversation or task across runs. See [sessions](getting-started/sessions.md). |
| Request | An input asking the agent to do work. Its request ID distinguishes it from other inputs and helps prevent duplicate delivery from creating another turn. | When queueing work or connecting a channel. See [data model](architecture/data-model.md). |
| Model message | A piece of conversation content, such as user text, an assistant response or a tool result. | When building model requests. See [model providers](reference/model-providers.md). |
| Tool | A callable operation exposed to the model, such as reading a file. A tool call is a request to perform that operation; availability does not by itself authorize it. | When adding actions. See [coding guide](guides/coding.md). |
| Skill | A package of instructions and resources that helps the agent perform a task. Loading it runs no script and grants no permission. | When adding reusable know-how. See [skills](design/skills.md). |
| Profile | Trusted configuration that defines how an agent may operate. Content found in a workspace cannot give itself this authority. | When configuring an agent. See [configuration](reference/config.md). |
| Capability | An operation bound to the agent's permitted scope. It connects available tools and services to the authority that allows their use. | When deciding what an agent can do. See [security model](architecture/security-model.md). |
| Plan | A proposed sequence of actions. For the reviewed change path, it is checked before material actions run. | When allowing changes. See [coding guide](guides/coding.md). |
| Approval | A recorded decision about an exact proposed operation. It does not grant permission for arbitrary later actions. | When reviewing a change or another controlled action. See [security model](architecture/security-model.md). |
| Verification | A check of whether the requested outcome was achieved. Finishing execution alone does not establish success. | When judging the result. See [coding guide](guides/coding.md). |

## Building a graph

| Concept | Meaning | When you need it |
|---|---|---|
| Graph | Nodes and routes that define how work proceeds. Compilation prepares the definition for execution. | When building a workflow. See [graph design](design/graph.md). |
| Node | A unit of graph work. It reads a shared, read-only state snapshot and returns updates. | When implementing workflow behavior. See [node state](adr/adr-007-frozen-state-is-handed-to-nodes.md). |
| State | The values carried through a graph, represented by a Ruby Hash. | When defining workflow inputs and results. See [state and reducers](adr/adr-006-plain-hash-state-with-an-explicit-reducer-registry.md). |
| Reducer | A rule for combining the current value with an ordered batch of updates. | When several tasks can update the same state field. See [graph design](design/graph.md). |
| Edge | A route from one node to another. Routes can be fixed or selected by graph logic. | When connecting nodes. See [graph design](design/graph.md). |
| Command / Send | Routing values used to choose what runs next or create task activations. | When using dynamic routes or fan-out. See [graph design](design/graph.md). |
| Context | Run information and services made available to node code. It is separate from the graph's state. | When accessing execution services. See [API reference](reference/public-api.md). |
| Super-step / barrier | A group of scheduled tasks runs from the same state snapshot. At the barrier, their results are combined and the next state is committed. | When reasoning about concurrency. See [graph design](design/graph.md). |
| Checkpoint | A committed snapshot of graph progress used for recovery and resume. It records progress, not proof that every external action succeeded. | When making work durable. See [data model](architecture/data-model.md). |
| Interrupt / resume | An interrupt pauses work for input. On resume, the node starts again and receives the recorded answers at its interrupt calls. | When asking questions or awaiting decisions. See [graph design](design/graph.md). |
| Subgraph | A compiled graph used as part of another graph. Its persistence mode determines whether child state continues across calls. | When composing workflows. See [graph design](design/graph.md). |
| Store | Durable records accessed through a store API, separate from one graph's state snapshot. | When sharing data across turns or threads. See [data model](architecture/data-model.md). |

## Recovery and operations

| Concept | Meaning | When you need it |
|---|---|---|
| Execution ID / graph version | The execution ID identifies a run; the graph version identifies the definition it uses. Resume must respect the recorded identity and compatible definition. | When debugging or changing durable workflows. See [graph design](design/graph.md). |
| Lease / fence | A lease gives a worker temporary ownership. An increasing fence token lets the store reject writes from an expired or replaced owner. | When running workers or recovering after a crash. See [writer ownership](adr/adr-017-one-fenced-writer-per-thread-namespace.md). |
| Effect journal / receipt | The journal records external or non-deterministic calls and their outcomes. A receipt lets recovery reuse a known result instead of blindly repeating the call. | When nodes call models, tools or external services. See [effect rules](adr/adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md). |
| Unknown outcome (`:unknown`) | An effect’s outcome is unresolved, so Tamoz blocks automatic progress pending evidence or a recorded human resolution. | After an ambiguous external call. See [sessions](getting-started/sessions.md). |
| Stop | A user's stop ends the current turn without aborting the underlying graph. | When cancelling work. See [stop behavior](adr/adr-057-a-user-stop-ends-the-turn-it-never-aborts-the-graph.md). |
| Request inbox / worker | The inbox holds admitted requests; a worker claims and advances them under the runtime's ownership rules. | When running unattended work. See [operator guide](guides/agent-operator.md). |
| Schedule / occurrence | A schedule describes when work is due. An occurrence is one due instance, delivered as a request; the scheduler does not execute the agent itself. | When scheduling work. See [scheduling](design/scheduling.md). |
| Backup / restore | Backup produces a consistent database copy. Restore and recovery need an operator procedure; copying only the main live database file is not a backup strategy. | When protecting or recovering data. See [operations](operations/operations.md). |
| Request series / header digest | A series groups model requests with stable fixed content. The digest fingerprints the header; it does not prove a provider cache hit. | When tracing request changes. See [stable requests](adr/adr-009-the-model-request-prefix-is-byte-stable-within-a-cache-epoch.md). |

## Other features

| Concept | Meaning | When you need it |
|---|---|---|
| Memory | Retained Experience, Knowledge and Wisdom, with provenance and rules for use and promotion. It is more than the current conversation. | When reusing past work. See [memory](design/memory.md). |
| Subagent | A child task with a bounded role and authority under a parent task. Instructions alone do not grant it more access. | When delegating work. See [deep research](guides/deep-research.md) for delegation and the [authority rules](architecture/security-model.md). |
| MCP / channel | MCP connects external tool services. A channel carries user input and responses, such as Telegram. They serve different roles. | When connecting services or users. See [MCP](design/mcp.md) and [communications](design/comms.md). |
| Situation / episode | A Situation is the sealed input Tamoz reasons over for an episode. Continuous event processing belongs to the separate `agentic-stream` system. | When integrating continuous input. See [streaming](design/streaming.md). |
| Signal / trace | A signal records an observable event; a trace connects events to the work that produced them. | When investigating behavior. See [observability](design/observability.md). |
| Evaluation / scorecard | An evaluation measures behavior under a defined procedure. A scorecard records the results; passing plumbing tests is not evidence of model reasoning quality. | When assessing changes. See [evaluation](guides/evaluation.md). |
| Self-healing / self-improvement | Healing handles bounded operational failures. Improvement proposes and evaluates behavior changes before controlled promotion. | When enabling these features. See [healing](design/self-healing.md) and [memory](design/memory.md). |

## Keeping this guide current

Adding or changing a public concept requires updating its explanation, when-needed guidance and
links here in the same change. There is no concept-count limit. Important failures and authority
boundaries must remain visible, even when they require another term. This is the rule in [ADR-013](adr/adr-013-public-vocabulary-is-a-budget-never-a-correctness-cap.md).
