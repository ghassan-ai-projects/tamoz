# Glossary — pattern-design r2

The pattern files use a dense private vocabulary. This is the single reference. Terms are
grouped; within a group they build on each other.

## The two identities

- **tamoz** — the Ruby repo (this one). The **judgment** worker: frames, reasons, proposes
  decisions. Runs as the gRPC *server*; the stream dials it.
- **agentic-stream** — the Go sibling repo (`~/my-projects/agentic-stream/`). The
  **authority**: validates, approves, executes commands. Runs as the gRPC *client* /
  supervisor. **Every `*.go` reference in these docs lives here.**
- **Two-identity split** — the load-bearing collaboration seam: the model *proposes*, the
  catalog *declares* authority, the stream *validates and executes*. Digests are verified at
  both boundaries so neither side has to trust the other's word.

## The graph

- **EpisodeGraph** — the fixed, compiled directed graph an episode runs on (`episode_graph.rb`).
  Iteration is graph state, never a Ruby `while` loop.
- **Spine** — a named path through the graph. **DIAGNOSE spine:**
  `intake → recall → build_frame → reason → validate → decide → END`. **RECONSIDER spine:**
  `intake → judge → compensate → END` (deterministic, zero model calls).
- **Node** — one step in the graph (e.g. `reason`, `validate`, `execute_tool`). `reason` is
  the only model-calling node in the DIAGNOSE spine.
- **Branch** — a routing decision out of a node (e.g. `branch :validate` routes to
  `decide | execute_tool | repair`).
- **State channel** — a named piece of episode state carried across steps (e.g.
  `tool_results`, `repair_count`, `step_cursor`, `judgements`). `reduce: :append` channels
  accumulate; the frame is rebuilt from them deterministically.
- **The loop** — `validate → execute_tool → rebuild_frame → reason`, bounded by
  `max_steps` (200). This is the ReAct cycle, expressed as graph structure.
- **Session** — a second fixed graph (`session.rb`) for the interactive path; it is the one
  place a real multi-step Plan/Executor runs (pattern-02).

## Determinism & the journal

- **Effect journal** — the durable log (`EffectDispatcher.run`) of every model/tool/recall
  call. Replay returns the recorded receipt, never a fresh answer.
- **Logical (call) key** — the deterministic key a journaled call is stored under:
  `(episode, stage, slot, request_digest)`.
- **Slot** — the per-stage ordinal that distinguishes repeated calls of the same kind
  (e.g. each tool result appends at the next slot).
- **Fence** — a monotonic guard that rejects stale/duplicate attempts for an episode
  identity (episode/attempt/fence on the wire).
- **Frame** — the assembled model input for one `reason` call (`EpisodeFrameBuilder`):
  system prompt + catalog + skills + memory + tool_results + directives. It is a **pure
  function of state**, so the next request digest is deterministic.
- **Digest** — a domain-separated SHA-256 over a canonicalized payload (snapshot, decision,
  intent, skill tree, handoff…). Verified at both boundaries; the communication contract.
- **Receipt** — the recorded outcome of a journaled call (identity, digests, bytes).
- **P3 (replay) contract** — because the frame is pure and every call is journaled under a
  logical key, the whole loop replays checkpoint-identically. Any change that alters a frame
  digest changes replay and must be reasoned about explicitly.

## Decisions, intents, risk

- **Intent** — a proposed action drawn from the **IntentCatalog** (type, risk_class,
  parameter_schema, presets, policy, rate_limit, compensation — all digest-bound). The model
  proposes an intent; it does not invent authority.
- **Actionable intent** — a non-watch, non-compensation intent. The production path allows
  **at most one** (`MAX_ACTIONABLE_INTENTS = 1`).
- **Watch** — the R0 "observe, don't act" condition; where `watch_preferred?` /
  `watch_confidence_floor` sends a low-confidence output. Abstention, not refinement.
- **Risk classes R0–R4** — the per-action autonomy gate:
  - **R0 / R1** — auto (execute without approval).
  - **R2** — human approval, *unless* an exact calibration artifact matches (then
    calibrated automation).
  - **R3 / R4** — deny (`risk_policy_denied`).
- **Calibration artifact** — the exact (domain + compiled-spec model revision) record that
  permits R2 to run automatically. Missing/mismatched → human approval. (P8.)
- **RECONSIDER** — re-adjudication of a prior action triggered by *late corrected data*
  (`completeness="corrected"` + `correct_and_reconsider`), resolved deterministically from
  catalog compensation metadata: **withdraw / downgrade / let_stand**.
- **Repair** — the one-shot in-episode retry (`repair_count < 1`) after a malformed model
  turn: a second journaled `reason` call under a changed frame digest. Syntax-level, not
  semantic critique.

## Tools, skills, memory

- **Capability host** — note **two files share this name**: the tool *router* in
  `gems/tamoz-tools/` and the **6-tool read-only evidence host** in `gems/tamoz-stream/`
  (`features.query, evidence.get, situations.related, history.prior_incidents,
  knowledge.search, forecast.run`). Always read the gem path.
- **Descriptor** — a tool's registry entry (name, dispatcher). "Descriptors not rendered in
  the frame" (pattern-01 G4) means the model must learn tools from the system prompt.
- **Effect class** — a tool's mutation category (`:read_only`, `:reconcilable`, …). Discovery
  is read-only; mutation requires approval.
- **SkillSet** — an ordered, digest-pinned list of skills `[{name, tree_sha256}]`; text is
  resolved only from an operator-approved source and must match the wire digest.
- **Tiers / epistemic kinds (memory)** — layers `experience / knowledge / wisdom`;
  `EPISTEMIC_KINDS = observed | reported | inferred | prescribed`. `:observed` requires an
  authenticated outcome reference.
- **Consolidation** — the model *proposes* a memory write; deterministic gates (recurrence,
  diversity, confidence, taint) *decide*.

## Human-in-the-loop

- **ApprovalRelay** — the Tamoz-side delivery lifecycle (deliver → submit_decision →
  withdraw). It relays; it never signs as the approver.
- **Assertion** — the signed, digest-bound approval record binding authority to the *exact*
  intent (approver, tenant, intent_digest, snapshot_digest, decision, expiry, nonce…).
- **Consume-once nonce** — a durable single-use token; a repeated nonce is *refused*, not
  idempotently accepted.
- **Re-validate on resolve** — on approve, the Go side re-runs the *entire* intent gate;
  the human's answer is an input to policy, never a substitute for it.

## The autonomy scale (handbook ch.00)

The single reference for the "Autonomy:" line every pattern file carries.

| Level | Name | One line |
|---|---|---|
| **L0** | Tool Assistant | Model suggests; human approves every step. |
| **L1** | Tool User | Tools invoked in a fixed workflow. |
| **L2** | Loop Agent | Model reasons, acts, observes, repeats (ReAct). |
| **L3** | Planner | Model produces and executes a multi-step plan. |
| **L4** | Collaborative | Multiple agents / hierarchy / debate. |
| **L5** | Autonomous Operator | Long-running, self-improving, minimal oversight. |

Tamoz sits at **L1–L2** on the production path (loop = L2, action surface = L1), reaches
**L3** on the interactive Session path, and has **L4** machinery present but dormant.
