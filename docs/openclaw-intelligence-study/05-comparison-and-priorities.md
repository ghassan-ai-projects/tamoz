# OpenClaw to Tamoz: intelligence comparison and priorities

## Executive decision

Tamoz should adopt OpenClaw's continuous action-observation experience and
capability visibility, while preserving Tamoz's stronger authority, durable
effects, approval evidence, secrets, and unknown-outcome semantics.

The first implementation is not “add every OpenClaw tool.” It is:

1. make the existing capability surface inspectable;
2. make the durable `Session` loop adaptive for bounded read-only work;
3. persist observations and expose continuation;
4. keep mutation and external effects governed;
5. add breadth only after measured composition works.

## Capability comparison

| Concern | OpenClaw | Tamoz today | Decision |
| --- | --- | --- | --- |
| Intelligence loop | Shared model → tool → observation → model loop | Session is mostly plan → ordered steps → evaluate; EpisodeGraph has a loop but is domain-specific | Add bounded durable continuation to Session |
| Tool breadth | Broad core, plugin, browser, node, media, messaging, MCP surface | Narrow local tools plus skills/MCP/websearch | Add only governed capability families |
| Tool discovery | Progressive search/describe/call and dynamic assembly | Phase-filtered names/descriptions; MCP schema is hidden from planning surface | Add bounded schema-aware discovery |
| Authority | Trusted Gateway/operator, layered tool policy | Closed-world source-qualified capability binding and operator authority | Preserve Tamoz boundary |
| Shell | Host/sandbox/gateway/node execution with approvals | Named checks with exact argv, no arbitrary shell | Keep Tamoz narrow by default |
| Web | Search, fetch, browser, SSRF/redirect guards | Reserved governed websearch MCP | Add web only as explicit source/effect domain |
| Database | No core arbitrary SQL; indirect via shell/MCP/skills | Internal SQLite only, no agent SQL | Keep persistence separate; add governed DB only if needed |
| MCP | Dynamic catalog/materialization, cooldown/reconnect, plugin trust | Pinned catalogs, supervised invocation, bounded/unknown effects | Add discovery/health UX; preserve Tamoz trust model |
| Config/state | Read-only Gateway state and privileged ring-zero mutation | Operator CLI/runtime inspection; no model-facing config tool | Add bounded read-only inspection; proposal-only mutation |
| Self-modification | Config/skill/update paths with approvals and rollback in selected flows | Candidate/promote/operator-gated workspace/behavior changes | Preserve candidate-only activation; no autonomous authority mutation |
| Memory/context | Session branches, memory tools, compaction, project memory | Verified memory and transcript fragments; no general compaction | Add compaction as durable context projection |
| Background work | Cron, isolated runs, subagents, goals, continuation | Scheduler materializes durable requests | Productize existing scheduler; use durable child tasks |
| Recovery | Retry/fallback/loop guards/restart/delivery recovery | Strong checkpoints, effects, unknown, reconciliation | Adopt liveness UX; keep Tamoz receipt semantics |
| Telegram/CLI | Rich shared lifecycle and channel-native progress | Shared durable substrate but sparse projection and inconsistent context | Unify lifecycle and context projections |
| Intelligence evidence | Strong plumbing/scenario coverage, limited general model proof | Strong safety/plumbing, limited independent model-use proof | Build matched real-provider composition benchmark |

## Adopt, adapt, reject

### Adopt

- continuous model/tool/observation continuation;
- bounded loop, idle, output, compaction, and repeated-action guards;
- progressive capability discovery and schema description;
- read-only state/capability inspection;
- visible tool/progress/approval/interruption lifecycle;
- durable background work and child-task product patterns;
- selective retries, cooldowns, and no replay after ambiguous mutation;
- compaction that preserves active work identifiers and constraints;
- scenario-driven live evaluation.

### Adapt

- OpenClaw's inline planning becomes a read-only adaptive mode, while Tamoz
  keeps explicit plan/review for mutations and high-risk work;
- dynamic tool catalogs become immutable, source-qualified, digest-bound Tamoz
  snapshots;
- MCP reconnect/cooldown becomes a supervised Tamoz effect/capability state;
- child agents become durable child requests, not in-memory sessions;
- rich approvals remain exact-digest, human-authorized, and channel-bound;
- config/skill updates become candidate → approval → apply → verify/rollback;
- progress becomes durable semantic projection, not raw model token streaming.

### Reject

- trusted Gateway as a sufficient authorization boundary;
- broad host shell or full/elevated execution as a default;
- arbitrary SQL against internal Tamoz state;
- tool-name allowlists as the only effect authority;
- prompt wrapping/detection as injection prevention;
- in-process untrusted plugin/MCP execution;
- approval-free active skill/profile/policy mutation;
- blind retries of ambiguous non-idempotent effects;
- treating audit absence as proof an effect did not occur;
- calling a model generally “more intelligent” from tool count or fixture tests.

## Priority order

### P0 — close capability authority gaps

Before adding breadth:

1. Make unknown/new capability safety fail closed rather than falling through to
   read-only classification.
2. Give every capability an explicit effect class, retry/reconciliation policy,
   approval evidence, egress, secret, budget, and schema digest.
3. Make effect identity support multiple adaptive/compound calls without receipt
   collision.
4. Fence MCP descriptions and remote results as untrusted data.
5. Keep scheduled request templates operator-owned and cannot be supplied by
   model/workspace content.

### P1 — expose the effective capability surface

1. Add read-only capability inventory with declared/configured/catalogued/
   materialized/reachable/authorized/effective/verified states.
2. Split `peek` from `materialize`; ordinary status must not start MCP processes
   or network connections.
3. Add bounded schema-aware local/MCP discovery.
4. Return structured unavailable reasons instead of failing an entire status
   response.
5. Add a bounded model-facing read-only state/config/session inspection tool.

### P2 — make `Session` adapt after observations

1. Add a new durable graph branch/version for one-action read-only continuation.
2. Persist observation, effect, iteration, provenance, truncation, and next-action
   state.
3. Use existing loop/repeated-action/budget/cancellation/unknown guards.
4. Stop and hand off to reviewed action mode for mutation or external write.
5. Preserve explicit model/provider role identity; avoid implicit fallback first.

### P3 — make context and autonomy feel continuous

1. Add durable context compaction with goal/constraint/effect/approval retention.
2. Align Telegram and durable CLI session/context identity.
3. Project tool starts/results, approvals, waits, checkpoints, and terminal state
   through the communication lifecycle.
4. Make scheduled occurrences, child tasks, and recovery handles visible.
5. Add durable child-task delegation with narrowed authority.

### P4 — expand capability families under gates

1. Governed browser capability.
2. Governed database capability, preferably through a supervised MCP/source
   adapter with explicit read/write semantics.
3. Richer messaging and external service effects.
4. Candidate-only config/skill/profile proposals.
5. Package/runtime self-update only after a dedicated approval, rollback, and
   restart-health program.

## Root cause and priority matrix

| Root cause | User consequence | First change | Risk if deferred |
| --- | --- | --- | --- |
| Session does not re-decide after each successful observation | Agent follows stale plan and feels unintelligent | P2 adaptive read-only branch | Wrong or incomplete open-ended work |
| EpisodeGraph is isolated | Best loop is unavailable to normal chat | Extract control shape into Session | Duplicate semantics and continued fragmentation |
| Tool schemas are hidden | Model guesses arguments and needs repair | P1 schema-aware discovery | Tools exist but are not effectively used |
| Capability status is opaque | User cannot understand why a tool is unavailable | P1 capability inventory | More tools add confusion, not capability |
| Runtime bypasses durable effects | Ephemeral mode diverges from safe chat | Keep clearly ephemeral; converge later | Duplicate side effects and inconsistent behavior |
| Context/transcript/memory are fragmented | Agent forgets working conversation | P3 compaction/context unification | Long tasks degrade or restart poorly |
| Progress projection is sparse | User assumes the agent is idle | P3 lifecycle projection | Perceived capability remains low |
| Safety classification has fall-through risks | New capabilities can be misclassified | P0 fail-closed descriptors | Capability expansion becomes unsafe |

## Recommended first vertical slice

Choose a read-only repository investigation mission:

```text
Telegram or durable CLI request
  -> request reference and capability inventory
  -> adaptive read-only model turn
  -> read/search tool through SessionEffects
  -> bounded observation with provenance
  -> model chooses next read/search action
  -> final evidence-backed answer
  -> same lifecycle projection and durable receipt
```

Success must require:

- no mutation or shell authority;
- tool schema and availability visible;
- every model/tool call journaled;
- loop bounded and restart-safe;
- duplicate request/effect does not duplicate work;
- Telegram and CLI share semantic trace;
- real-provider run separately recorded from fixture plumbing;
- user sees progress and final evidence.

## Measurement gates

Do not claim “more intelligent” until the matched benchmark reports:

- tool selection and argument correctness;
- task completion and verification;
- unnecessary tool calls;
- unauthorized-action rate;
- duplicate and unknown-effect rate;
- recovery after restart/failure;
- latency, token, and tool-output cost;
- Telegram/CLI semantic parity.

Use both:

1. a common-subset track with matched provider/model, task, permissions, budget,
   and equivalent tools;
2. a native-envelope track that reports capability availability separately from
   model performance.

The existing benchmark controls already distinguish fixture plumbing from real
intelligence evidence. Extend that discipline rather than weakening it.
