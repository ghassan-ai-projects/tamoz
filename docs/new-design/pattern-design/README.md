# Agentic Patterns on Tamoz — design folder

Source of truth for "which agentic pattern does Tamoz implement, how, and how it
SHOULD be implemented." Patterns are defined in the owner's handbook
(`~/my-projects/personal-website/handbook/md/chapter-00..07-*.md`); this folder
maps each onto the actual code (HEAD: smarter-tamoz, 2026-08-16), records the
divergence, and gives the correct-implementation design tied to existing seams.

**Status: design only — no code changed.** Produced by 5 discovery agents (one per
pattern family, evidence at file:line against the working tree) + 2 design reviewers.

## The substrate: the graph, the journal, the two-identity split

Every pattern below runs on the same substrate:

- **A fixed, compiled graph** (`Tamoz::Agent::EpisodeGraph` v4, `tamoz.agent.episode`,
  `gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb`). DIAGNOSE spine
  `intake → recall → build_frame → reason → validate → decide → END` with a bounded
  `validate → execute_tool → rebuild_frame → reason` loop and one-shot `repair`;
  RECONSIDER spine `intake → judge → compensate → END` (deterministic, zero model calls).
  The interactive Session is a second fixed graph (`tamoz.agent.session`,
  `session.rb`). Loop iteration is graph state, never a Ruby `while`.
- **A durable effect journal** (`EffectDispatcher.run`, `effect_dispatcher.rb`): every
  model/tool/recall call is journaled under a deterministic logical key
  `(episode, stage, slot, request_digest)`; replay returns the recorded receipt, never
  a fresh answer. The frame is a pure function of state → the next call's request
  digest is deterministic → the whole loop replays checkpoint-identically (P3 contract).
- **Budget + termination** are structural: pre-dispatch budget checks
  (`ReceiptBudgetController`), graph `max_steps` (200, `executor.rb`), wall-clock
  deadline, and typed failure terminals — never blind retries.
- **Two-identity split (the load-bearing collaboration seam):** agentic-stream owns
  authority (validates, approves, executes commands); Tamoz owns judgment (frames,
  reasons, decides). Digests are verified at BOTH boundaries; the model proposes,
  the catalog declares authority, the stream validates. R2 automatic dispatch is
  additionally gated by an exact calibration artifact (domain + compiled-spec model
  revision — policy.go:313-320); missing/mismatched → human approval, never silent
  automation.
- **The autonomy scale (handbook ch.00):** L0 Tool Assistant (human approves every
  step) → L1 Tool User (tools in a fixed workflow) → L2 Loop Agent (reason-act-
  observe) → L3 Planner (multi-step plan) → L4 Collaborative → L5 Autonomous
  Operator. Each pattern file carries an Autonomy line.

## Pattern verdicts (summary)

| Pattern | File | Verdict | Autonomy | Headline |
|---|---|---|---|---|
| 01 ReAct / cognition loop | pattern-01-react-loop.md | **Partial** | L1-L2 (loop = L2, action surface = L1) | Loop exists but tool turns carry no Thought and Observation is metadata-only → "gather-then-judge", not ReAct. |
| 02 Plan-and-Execute | pattern-02-plan-and-execute.md | **Partial** | Production L1-L2, Session L3 | Session path is the pattern; production path is single-decision (≤1 intent), no re-plan on rejection. |
| 03 Reflection | pattern-03-reflection.md | **Partial** | L2 (+ deterministic adjudication) | RECONSIDER is deterministic + externally triggered; no in-episode rubric critique. |
| 04 Multi-agent collaboration | pattern-04-multi-agent-collaboration.md | **Partial** | 2-party L2-L3; machinery for L4 dead | Two-party supervisor/worker with digest contracts (strong); no orchestrator, no debate gate, subgraph/Send/fork machinery dead. |
| 05 Tool use & skill registry | pattern-05-tools-and-skills.md | **Strong** | L1 tool surface | Resolve-first-execute, idempotency, sealed registry all conform; missing per-tool schemas/versions, structured error classes, breakers. |
| 06 Memory & context | pattern-06-memory-and-context.md | **Strong** | n/a (support) | Permissioned, provenance-rich, deterministic recall; missing semantic supersede-resolution, compaction, context budget split. |
| 07 Human-in-the-loop | pattern-07-human-in-the-loop.md | **Strong** | per-action R0-R4 gate | Digest-bound exact-intent approval + consume-once + full revalidation (best-in-class); missing revise rung, escalation ladder, friction budget. |

## Cross-cutting design principles (apply to every pattern)

1. **Patterns land on the graph, not next to it.** A new loop is a new node + branch +
   state channel; a new collaboration is a supervisor node dispatching via
   `DurableRunner.submit`; reflection is a journaled second model call. The
   determinism contract (logical-key journaling, pure frame, digest-bound handoffs)
   is the invariant every extension must preserve.
2. **The journal is the iteration carrier.** Iteration, re-planning, critique, and
   tool execution are all journaled calls with changed frame digests — replay
   reconstructs the identical sequence. Never introduce an unjournaled loop.
3. **Determinism beats model judgment where a rule exists.** The catalog declares
   intent authority, the judge compensates from catalog metadata, the confidence
   floor abstains, consolidation gates the model's proposal. Model calls are for
   judgment only (one node per pattern where possible).
4. **Bound everything that iterates:** every new loop needs a count channel
   (`repair_count`-style), a budget check, and a typed terminal for "exhausted
   without decision".
5. **Digest discipline is the communication contract** — handoffs, decisions,
   snapshots, skills, tools all carry domain-separated digests verified at both
   boundaries. Extend it to any new inter-agent payload.
6. **Defer what the handbook allows you to defer**: vector semantic search, sagas,
   long-running job contracts, relevance retrieval — none is warranted at current
   scale; document the deliberate divergence instead of adding machinery.

## Sequencing (gap prerequisites)

- **01 first:** G1 (tool-turn Thought) + G2 (execute all tool requests) precede
  anything that makes the loop informative; the protocol bump v2→v3 happens ONCE,
  in 01.
- **03 second:** R1 (critique node) lands on the same `branch :validate` and reuses
  01's journaled model-call seam — it is only informative after 01's loop carries
  content.
- **02 after 01:** P1 (PLAN route) generalizes the loop 01 just built; sequence it
  after 01's G2 executor change.
- **07 H5's "alternatives" source** is 03's critic; **04 M1's supervise dispatch**
  reuses 02's executor loop.
- The "01 is highest-leverage" headline presupposes the **G3 decision**: if G3
  resolves to metadata-only observations, 01's work is "document bounded
  gather-then-judge" rather than "make the loop ReAct-informative". Decide G3 before
  sequencing the rest.

## Reading order

README → 01 (substrate cognition) → 03 (reflection builds on 01) → 02 (planning
wraps 01/03) → 04 (collaboration uses the graph substrate) → 05/06/07 (supporting
patterns). Each file ends with a priority-ordered gap list; the highest-leverage
work is 01 (make the loop ReAct-informative) and 03 (in-episode critique), both
landing on the same `validate` branch without new machinery.
