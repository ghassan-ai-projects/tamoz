# Subagent topologies — design

Follows [`../subagents-2026-09-29/`](../subagents-2026-09-29/FINDINGS.md): the `delegate` mechanism works, but the
first real-model run was inconclusive because a single search solved every "broad" task. This round builds the
instrument that can tell topologies apart, then the topologies, then the signals that help the parent choose.

## 1. Topologies are a small, fixed set

The parent is always the orchestrator and the only writer. Children never talk to each other, never nest, never write.
What varies is how the parent fans work out and what it asks for:

| Topology | Tool call | Children | Status |
|---|---|---|---|
| solo | none | 0 | exists |
| sequential explore | `delegate {role: explore, brief}` | 1 per call | exists |
| **fan-out explore** | `delegate {role: explore, briefs: [..]}` | one per brief, run concurrently, merged into one result | new |
| **fresh-context review** | `delegate {role: review, brief}` | 1, handed the parent's changed paths by the harness | new |

Each is data: roles in `subagent_roles.json`, limits there too. No new store, thread, queue, effect type or gem edge.

### 1.1 Fan-out

- `briefs` is 2–4 independent briefs (`max_fanout` in the roles file). Each is validated like a single brief.
- Children run as parallel subgraphs of the parent's gate node (`SubgraphRuntime` already allocates call indexes under a
  mutex and gives each call its own namespace, execution id and request id). The engine's pool is not used from inside a
  node; the node runs one Ruby thread per child and joins them, re-raising any exception on the node's thread.
- Result: one tool result, sections in brief order, each the single-child format; each answer cut to
  `4096 / n` bytes (whole answers spilled), so the parent's surface grows by at most one single-child result.
- The per-turn cap counts children, not calls: a fan-out of 3 spends 3 of the 4.

### 1.2 Review

- Role `review`: read-only tools like explore, its own prompt (find defects in a change; report each as file:line with
  why; say "no defects found" plainly), smaller budget.
- The harness appends to the brief the paths the parent changed this turn, from `work_changes` (the durable record),
  never from the parent's prose. With no change yet, `review` is refused before any child runs.

## 2. Helping the parent choose

1. **Tool guidance** (prompt files): when each topology fits and when it does not, in concrete terms.
2. **Harness notes**: when a turn crosses a threshold and has not delegated, the harness appends one short
   `system_update` suggesting delegation. Two triggers, thresholds in the roles file:
   - `nudge_reads`: distinct files the parent has read this turn;
   - `nudge_window`: estimated prompt tokens as a fraction of the compaction threshold.
   At most one note per turn; appended, never rewriting an earlier message (the prompt cache is prefix-exact).
3. **Measurement**: the hard pack tags each scenario by shape; the report states success and cost per shape and
   topology, so guidance is tuned against evidence, not taste.

## 3. The hard pack

Every `broad` scenario must defeat a single search. That is checked, not hoped (bar H1–H3):

| Id | Shape | The work |
|---|---|---|
| HA1 chain | `chain` | a wrong total; the cause is reached only by following reads through config indirection (keys built at runtime, aliases); the needle file shares no distinctive token with the prompt or the failing output |
| HA2 survey | `survey` | list which of ~40 handlers mutate their argument: each file must be read and understood; no regex separates them |
| HA3 big survey | `survey` | the same over files whose total size is several times the parent's window at 32K — a solo parent must compact |
| HA4 review | `change` | implement a small change whose obvious edit breaks a second, untested caller; a fresh-context read of the change finds it |
| HA5 narrow | `narrow` | one obvious place |
| HA6 trivial | `trivial` | a one-line fix |

Seeds 1–2 are the **development set** (prompts may be tuned against them, labelled as such); seeds 3–4 are **held out**
and run once, at the end, for the reported numbers.

## 4. Out of scope

Peer-to-peer children, nesting, writing children, a learned router. The research and the first run give no evidence
for them; each reopens authority and approval questions.
