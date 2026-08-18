# Pattern 01 — The Core Cognition Loop (ReAct)

> **Rev 2 · 2026-08-16.** Symbol names are the authoritative anchor — **line numbers are approximate** (written against tamoz `smarter-tamoz`@`5b07557` / agentic-stream `smarter-agent`@`2e8aa3a`; HEAD `ebf1e23` / `c067127`). **`*.go` refs live in the agentic-stream repo; `*.rb` in tamoz.** See [`README.md`](README.md) · [`00-REVISION-NOTES.md`](00-REVISION-NOTES.md) · [`GLOSSARY.md`](GLOSSARY.md).

Handbook: chapter-00-agentic-landscape.md + chapter-01-react-pattern.md. Verdict:
**Partial — the loop is "gather-then-judge", not ReAct.** The reason→act→observe
cycle exists on the graph, but the Observation channel carries provenance, not
content, and tool turns carry no Thought. Builds on: README substrate (journal,
budget, two-identity split). **Autonomy: L1-L2** — the loop reaches handbook Level
2, the action surface stays Level 1 (fixed read-only allowlist), Level 3 (planner)
is deliberately not pursued.

## Handbook definition (owner's)

- TAO loop: Thought (reasoning trace) → Action (tool call) → Observation (tool
  output fed back as context); interleaving lets the agent adapt from real-world
  feedback. "Always generate a Thought before an Action. Only call one tool at a
  time. Wait for the Observation before the next Thought."
- Thought Trace is the verbal reasoning before committing to an action; without it
  agents suffer action-blindness. Strict separation: LLM writes Thought/Action,
  **System writes Observation** (anti-hallucinated-tool-results).
- When: exploratory/multi-step tasks, answers depending on external changing data.
  Avoid: single-turn deterministic tasks, latency-critical paths, fixed DAGs.
- Termination: hard iteration caps (5-10), time limits, explicit exit conditions;
  `max_steps` exceeded → distinguishable "gave up without final answer".

## How tamoz implements it (HEAD)

- **The loop is graph-structural:** `branch :validate` routes
  `decide | execute_tool | repair`; `execute_tool → rebuild_frame → reason` is the
  iteration carrier (episode_graph.rb:116-125). Iteration state = graph state
  (`model_receipts`, `tool_results`, `repair_count`, `budget_state` — episode_graph.rb:44-49).
- **Thought:** `EpisodeNodes#reason` (episode_nodes.rb:377-425) is the only
  model-calling node; pre-dispatch budget check; journaled via `EpisodeModelCall`
  under logical key `(episode, stage, slot, request_digest)` (episode_model_call.rb:32-66).
  Output contract `tamoz.episode-diagnosis/v2`: a turn is EITHER terminal
  (primary_hypothesis + diagnosis_probabilities + evidence_refs + recommended_intents)
  OR a tool turn (≤8 tool_requests), never both (reasoning_document.rb:100-102).
- **Observation:** tool results enter the frame **metadata-only**
  `{id, name, request_sha256, result_sha256, is_error, result_bytes}`
  (episode_frame_builder.rb:142-155) — never content. The model knows a tool ran and
  its digest, cannot read the payload. Evidence refs are grounding-checked against
  the frame (`ground_evidence!`, episode_nodes.rb:604-612) — the System-writes-
  Observation rule, enforced mechanically, stronger than the handbook's prompt level.
- **Action:** `execute_tool` (episode_nodes.rb:457-492) executes only
  `tool_requests.first`; the other 7 are silently dropped. The tool surface is the
  fixed 6-tool read-only allowlist (`features.query, evidence.get,
  situations.related, history.prior_incidents, knowledge.search, forecast.run` —
  tamoz-stream/lib/tamoz/stream/capability_host.rb:31-35), byte-capped, journal/store scrubbed from context.
- **Termination:** 3 layers — pre-dispatch model-call budget (receipt_budget_controller.rb),
  graph `max_steps` 200 (executor.rb:28-31), wire deadline (situation_request.rb:711-719);
  repair exactly once (`repair_count < 1`, episode_nodes.rb:449-455).
- **Autonomy level:** L1-L2 hybrid — the loop is L2 (reason-act-observe), the action
  surface is a fixed read-only allowlist (L1), and the intent catalog + risk ceiling
  cap the decision (catalog declares authority). Level 3 (planner) is deliberately
  not pursued in the production path (see pattern-02).

## Divergence from the handbook

1. **Thought and Action are structurally separated** — a tool turn cannot carry a
   thought (parse rejects terminal fields on tool turns). Adaptation happens across
   iterations with no visible rationale on the action path: the inverse of
   action-blindness — *thought-blindness on the action path*.
2. **Observation is metadata, not data** — the next Thought cannot use fetched
   content; the loop is non-informative ReAct ("gather, then judge"). Anti-
   hallucination is perfectly solved; information-gathering is not served.
3. **8 tool requests accepted, 1 executed** — the contract advertises parallel calls
   (which the handbook's FAQ flags as attribution-complicating) and the runtime
   truncates to one.
4. **No tool schema/descriptions in the frame** — the model must learn the six
   tools from the operator-authored system prompt; the handbook's machine-readable
   tool contract is absent (capability_host.rb:98-110 `descriptors` are never rendered).
5. **No context-bloat management** — the frame grows linearly with `tool_results`;
   no summarization or sliding window.
6. **`EpisodeBudget.wall_time` is validated but inert** — the separate deadline field
   enforces time; the budget field is a dead claim (`budget_hash`, situation_request.rb:96-110,
   omits `wall_time`).
7. **No distinct "exhausted without decision" terminal** — recursion-limit failure
   folds into generic graph failure.

## How it SHOULD be implemented (on existing seams)

1. **Let a tool turn carry a bounded Thought.** Add an optional `reasoning` field to
   the tool-turn schema; `parse_tool_turn` stops rejecting a narrowed terminal-key
   set (allow `primary_hypothesis`, keep rejecting `diagnosis_probabilities`);
   bump the protocol string v2→v3 (reasoning_document.rb:23,100-112). The repair
   path already proves the "system feeds failure context back into the next frame"
   seam.
2. **Execute all proposed tool requests sequentially, journaled per-slot.**
   `execute_tool` iterates `tool_requests` instead of `.first`; each request is
   journaled under slot `tool_results.length..+n` (EpisodeToolCall already keys on
   slot); budget-check per request; rebuild the frame once. Determinism contract
   intact (append-reduce `tool_results`, per-slot logical keys). Sequential
   execution in one iteration honors "one tool at a time" without truncation.
3. **Decide the Observation contract explicitly — content preview or metadata-only.**
   Option (a): include a byte-truncated content preview bounded by the existing
   `max_tool_result_bytes`/capability caps (frame digest then varies → replay stays
   stable, next call fresh). Option (b): keep metadata-only and document the episode
   as "bounded gather-then-judge" (ReAct-shaped, not ReAct-powered). This is the
   load-bearing design choice of the whole pattern: it decides whether the loop is
   information-gathering or judgment-with-provenance.
4. **Surface the tool contract in the frame** — render the capability host's
   `descriptors` (name/description/schema) into the system section; the catalog
   digest discipline keeps it pinned (see pattern-05).
5. **Add a distinguishable terminal for iterations-exhausted-without-decision**
   (map the `RecursionLimitError`/budget path to an explicit terminal reason).
6. **Bind `wall_time` into the budget hash or drop the field** — one honest source
   of time enforcement.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| G1 | Tool turns carry no Thought | `parse_tool_turn` (reasoning_document.rb:100-112) + protocol v3 + `document_projection` |
| G2 | Only 1 of ≤8 tool requests executes | `execute_tool` loop over `tool_requests` (episode_nodes.rb:460) |
| G3 | Observation content invisible to the model | frame tool entries (episode_frame_builder.rb:142-155) — decide content-preview vs metadata-only |
| G4 | Tool contract not machine-readable in the frame | render `capability_host.rb:98-110` descriptors into `build_system` |
| G5 | No context-bloat management | frame builder (summarize/sliding window over `tool_results`) |
| G6 | `wall_time` budget field inert | budget_hash (situation_request.rb:96-110) |
| G7 | No "exhausted without decision" terminal | executor.rb:28-31 recursion path → typed reason |
| G8 | Autonomy deliberately capped (loop = L2, action surface = L1, no planner) | **defer-by-design** — document the bounded-autonomy choice |

**Replay impact (G3 — the load-bearing choice):** metadata-only Observation keeps the
frame digest independent of tool *content*, so the loop replays byte-identically. A content
preview makes the frame digest depend on fetched bytes; replay stays deterministic (the
preview is journaled with the tool receipt) but the change re-opens the prompt-injection /
hallucinated-result surface the metadata-only design closed. Decide G3 with that tradeoff
explicit.

**Tests to update:** protocol v2→v3 touches the reasoning-document conformance
fixtures (which assert exact `reasoning_document/<code>` failures) and
`test/stream_episode_*` document-shape tests; G2 changes `execute_tool` behavior
covered by `test/stream_episode_loop_test.rb` (and the protocol change also touches
`test/agent_reasoning_document_test.rb`).
