# P2 — Phase report: durable loop and honest budgets

Status: **review pass in progress** (5 reviewer agents); core gates verified.

## Claims made (finished line)

**"The real path is durable."** — claim **level 3 of 6** (jointly with P3's
replay gate). The loop, the repair, the tool calls, and the budgets are all
durable journal semantics; the fixture runs are labeled `fixture` and never
shown as evidence of reasoning.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | Crash/redispatch matrix (fence+1, no duplicate call, no stale acceptance, no silent retry) | **PASS** | P1 crash matrix (expanded) + `stream_episode_replay_test.rb` ambiguous case: seeded started-without-receipt → typed FAILED, no second provider call |
| 2 | Completed receipt replays with provider network disabled — same parsed document, same decision | **PASS** | `stream_episode_replay_test.rb` gate-2: endpoint stopped, fence+1 → zero new calls, byte-identical document + tool results + decision (per-run fields stripped) |
| 3 | Ambiguous call stays unknown, never auto-repaired with a blind second call | **PASS** | ambiguous test: the seeded in-flight attempt → typed unknown (the reason node raises, no blind retry) |
| 4 | Tool happy + refusal paths journaled with digests and byte counts | **PASS** | `stream_episode_loop_test.rb`: tool results carry request/result digests + byte counts, success + refusal paths; catalog validation fail-closes |
| 5 | Budget exhaustion mid-loop → typed terminal, visible in cost reporting | **PASS** | pre-dispatch check (B7): max_model_calls=1 → the second call is NEVER made; terminal `BUDGET_EXHAUSTED` from the typed category |
| 6 | Repair fires once after a succeeded-malformed response, then stops | **PASS** | loop test: malformed → repair → valid (1 repair); two malformed → FAILED, no third call |
| 7 | Repository gates | **PASS** | `rake ci` green (exit 0); enola no-new-edge check from P1 held |

## What shipped

- **The loop as graph branches** (EpisodeGraph v2): `branch :validate` routes
  on the validate node's `next_node` — decide / execute_tool / repair — with
  `execute_tool → rebuild_frame → reason` and `repair → rebuild_frame →
  reason` cycles bounded by `Limits#max_steps` (no Ruby counter).
- **execute_tool** (EpisodeNodes + EpisodeToolCall): the model's tool request
  is validated against the wire tool catalog (fail closed), then executed as a
  journaled `unsafe` effect under a LOGICAL key (episode, "tool", slot,
  arguments digest) — replayed executions reuse the receipt; a crashed
  mid-call attempt is typed `unknown`. Results (success AND refusal) are
  journaled with request/result digests + byte counts, appended to
  `tool_results`.
- **rebuild_frame**: appends the attributed tool results (`tool:<slot>` refs)
  and the repair directive to the frame's user section — deterministic, so the
  next reason call's logical key is deterministic.
- **repair (exactly once)**: a succeeded-but-malformed response re-enters
  reason with the parse error as a repair directive (the frame digest changes
  → a NEW journaled call, never a blind retry); a second malformed response
  terminates typed.
- **ReceiptBudgetController**: budget enforcement FROM RECEIPTS as a pure
  projection of committed state — pre-dispatch CHECK (never a debit), post-call
  reconcile from the journaled receipt (missing usage stays unavailable, never
  zero); `budget_state` is a checkpointed graph channel, so replay reconciles
  identically. The wire `EpisodeBudget` envelope flows into the graph (all nine
  fields; nil = unbounded).
- **Typed terminals from categories**: `stream_error_data` now reports the
  ORIGINAL error class through the NodeError wrapper, so the runner maps
  `stream_budget_exceeded` → `TERMINAL_STATUS_BUDGET_EXHAUSTED` and the timeout
  category → `TERMINAL_STATUS_TIMED_OUT`.

## Fixture vs real labeling

All loop/replay tests use the fixture endpoint + stub evidence tool (labeled
`fixture`). The real-model run from P1 is unaffected (graph v2 is
backward-compatible with the single-call path — the P1 tests pass unchanged).

## Review outcomes (5 reviewer agents)

- **Fixed:** the tool port now comes from `context.episode_tools` (the
  per-run capability host the runner binds) with the construction-time port as
  a test-injection fallback — a production episode with a tool request no
  longer crashes on a nil port (architecture BLOCKER).
- **Fixed:** the wire model ordinal is now the call's position in the episode
  (`model_receipts.length`) — a loop episode emits distinct ordinals (0, 1,
  …), never a collision (architecture MAJOR).
- **Fixed:** the budget controller now also enforces `max_input_tokens`
  post-reconcile (honest budgets — no silently-ignored configured field);
  `EpisodeToolCall::Result.outcome` (dead field) removed (soundness MINORs).
- **Documented as P2-acceptable:** a Context deadline expiry surfaces as
  `CANCELLED` (the executor's cancelled path), not `TIMED_OUT` — the exit
  gates do not require TIMED_OUT; the TIMED_OUT mapping covers node-escaped
  timeouts. `max_provider_retries` is unconsumed by construction (the episode
  path never retries — unknown stays typed); `max_tool_result_bytes` is
  enforced by the capability host directly from the wire envelope.

## Deferred

- Tool events on the WIRE (ToolLifecycle): the phase journals tool calls; wire
  tool events land with the witness gateway (P3) or the tool-surface work.
- Multiple tools, skills/memory in frame (P5), witness gateway (P3), intent
  catalog (P4), per-call ordinals.
