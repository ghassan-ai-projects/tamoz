# P2 — Implementation plan: durable loop and honest budgets

Status: **draft v1** — reviewed by gap-searcher + completeness-checker before
implementation.

Bar: PHASE_P2_DURABLE_LOOP.md exit gate (7 items). Bars exercised: B2, B3, B7.
Claim: **"The real path is durable."** Level 3 of 6 (jointly with P3).

## Architecture (delta from P1)

```
START → intake → build_frame → reason → validate ──► decide → END
                                             │ (tool_request)
                                             ├─► execute_tool → rebuild_frame → reason  (loop)
                                             │ (malformed-after-success, repair_count<1)
                                             ├─► repair → reason
                                             │ (malformed-after-success, repair_count==1 | failed/unknown)
                                             └─► typed terminal
```

- **Loop as branches.** `validate` writes `next_node` (:decide | :tool |
  :repair | :terminal); the graph routes on it (session.rb branch pattern).
  The bound is `Limits#max_steps` — no Ruby counter.
- **State channels added:** `tool_results` (reduce: :append, []), `repair_count`
  (default 0), `budget_state` (the receipt-reconciled budget projection),
  `document_route` (the validate routing decision).

## Verified wire facts (P0B already landed the coordinated extension)

- `EpisodeBudget` (runtime-v1): `wall_time`, `max_model_calls`, `max_input_tokens`,
  `max_output_tokens`, `max_tool_calls`, `max_tool_result_bytes`,
  `max_total_tool_result_bytes`, `max_provider_retries`, `max_cost_microunits` —
  all present in the Ruby gen AND the Go proto (1d55801). **The coordinated
  version bump the phase doc names is the P0B wire extension; P2 consumes it.
  No new proto change needed.** The worker executor already sends `Budget`.
- `BudgetUpdated` event: `remaining`, `cumulative_usage`, `model_calls_used`,
  `tool_calls_used`, `tool_result_bytes_used`, `provider_retries_used`.
- `TerminalStatus`: `TIMED_OUT` + `BUDGET_EXHAUSTED` enum values exist.
- `ToolLifecycle` + `ToolState` (REQUESTED/STARTED/COMPLETED/BLOCKED) exist.
- **Graph cycles are supported** — the session path's step loop
  (step_gate → step_execute → evaluate → step_gate via branches) proves the
  durable runner handles branch cycles bounded by `Limits#max_steps`.
- The runner already validates the budget envelope (validate_budget!:
  wall_time + max_model_calls ceilings) and threads the capability host with
  the wire's max_tool_result_bytes.

## Tasks

### T1 — execute_tool node (tamoz-agent)

- Reads the validated document's `tool_requests` (first request only — one
  evidence tool per design).
- Validates the tool name + arguments against the REQUEST's tool catalog
  (wire `tool_catalog_json` → name + parameter presence; unknown tool /
  arguments not in the catalog → typed terminal, never a blind execution).
- Calls the tool via the injected tool port (`context.episode_tools.execute`)
  through `EffectDispatcher.run` with `safety: :unsafe` and a LOGICAL key
  (episode_id, stage: "tool", slot: N) — the same journal mode as the model
  call, so a crash after `dispatch_started` is typed `unknown` and a replayed
  completed tool call reuses its receipt (no duplicate execution).
- The result is digest-bound (`result_sha256`), size-capped (the capability
  host caps it), and attributed to the request; stored as a tool-result
  projection (codec-safe) appended to `tool_results`.

### T2 — rebuild_frame (frame accumulates tool results)

- After a tool execution, the frame's user section appends the tool results
  (name, request digest, result digest, byte count) as attributed evidence
  (`tool:<slot>` refs available to the model).
- Deterministic: same tool results → same frame bytes → same logical call key
  for the next reason call.

### T3 — repair (exactly once)

- `repair_count == 0` after a succeeded-but-malformed response → the repair
  node increments the count and re-enters `reason` with a repair directive in
  the frame (the malformed document's parse error message becomes part of the
  prompt: "your previous output failed to parse: <reason>. Output the JSON
  document only."). The frame digest changes → a NEW logical call key → a
  fresh (journaled) call — never a blind retry of the same request.
- `repair_count == 1` and still malformed → typed terminal (malformed).

### T4 — validate routing + strict parsing

- `validate` now routes: parse failure → :repair (when count < 1) or
  :terminal; `tool_requests` present → :tool; else → :decide.
- Grounding checks stay; the document projection gains the route.

### T5 — ReceiptBudgetController (tamoz-agent, injected into nodes)

- Constructed from the episode's wire budget envelope (model_calls, tokens,
  cost, tool_calls, tool_result_bytes — the Agentic Stream budget fields).
- **Pure projection, never imperative mutation.** `budget_state` is a
  checkpointed graph channel; each node update recomputes it as a pure
  function of (committed `budget_state`, the journaled receipt). A replayed
  or fence+1 redelivered run reproduces the SAME committed states, so the
  reconciliation is identical (gate 2: replay with provider network disabled
  reproduces the same budget projection and the same decision).
- **Pre-dispatch reservation is a CHECK, not a debit:** before each model/tool
  call, verify `committed_state.calls + 1 <= max_model_calls` (and the output
  allowance); exhaustion raises `BudgetExceededError` (typed) BEFORE the call.
  A reused receipt (EffectDispatcher `reused: true`) reconciles the SAME usage
  the original counted — never a double count and never a fresh provider call.
- **Post-call reconciliation:** from the journaled receipt (input/output
  tokens, cost; missing usage stays `usage_unavailable`, never zero).
- `Limits#max_steps` bounds the loop; the budget controller bounds calls.

### T6 — Wire + runner

- The runtime-v1 `budget` envelope (already on the proto) flows from the
  runner into the graph composition (per-run budget, like the wire's other
  fields). Old-version rejection on the coordinated bump: the worker rejects
  protocol_version < the bumped version (runner admission).
- Terminal mapping restores `TERMINAL_STATUS_BUDGET_EXHAUSTED` /
  `TIMED_OUT` from the typed errors (the P1-deleted mapping returns, driven
  by receipts/limits — not counted events).
- Deadline/cancel: already threaded via Context (no new machinery).

### T7 — Tool catalog on the wire

- The runner payload already carries `tool_catalog_json`; the intake node
  validates the document's tool requests against it (fail closed).

### T8 — Tests (exit gate)

- **Crash matrix (expanded):** before dispatch_started, after it, after
  receipt, after checkpoint, after decision, before terminal — fence+1
  redispatch: no duplicate provider call, no stale acceptance, no silent
  retry (per stage).
- **Replay with provider network disabled:** completed receipt replays →
  same parsed document, same decision (transport that raises on call when a
  receipt exists).
- **Ambiguous stays unknown:** never auto-repaired with a blind second call.
- **Tool happy + refusal paths** journaled with digests + byte counts.
- **Budget exhaustion mid-loop** → typed terminal, cost visible.
- **Repair fires once** after a succeeded-malformed response.
- Full repo gates at phase end.

## Go side (agentic-stream)

- The worker executor already sends the budget envelope; verify the fields
  map to the Ruby wire budget (model_calls, tokens, cost, tool_calls,
  tool_result_bytes) + the coordinated version bump (runtime-v1).

## Deferred (stated)

- Multiple tools, skills, memory in frame (P5), witness gateway (P3), intent
  catalog (P4).
