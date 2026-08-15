# P2 — Durable loop and honest budgets

Bar rules exercised: B2, B3, B7.

## Goal

The reason ↔ tool loop and the one-shot repair become graph branches. Every call is a journaled
unsafe effect with honest crash semantics. Budgets are enforced from receipts and graph limits,
not from counted events.

## In scope

- **`execute_tool` node.** Model requests a tool in the `ReasoningDocument`. The node calls the
  evidence tool through `EpisodeCapabilityHost` → `EvidenceTools` gRPC. One evidence tool only.
  Arguments validated against the request's tool catalog. Results digest-bound, size-capped,
  attributed, added to the next frame.
- **Loop as branches.** `validate` routes: valid → `decide`; tool request → `execute_tool` →
  rebuild frame → `reason`; malformed-after-success → `repair` (exactly once) → `reason`;
  failed/unknown → typed terminal. The bound is `Limits#max_steps`, not a Ruby counter.
- **Unsafe effect semantics.** Episode model/tool calls are `unsafe`, not session-default
  `idempotent`. Logical call key is stable across attempts/fences. After durable
  `dispatch_started` without a completed receipt: `unknown`, no blind retry. Provider SDK
  auto-retries disabled; every network attempt is an explicit sub-receipt.
- **Budgets from receipts.** Pre-dispatch reservation of one call, max output tokens, cost, retry
  allowance against the episode envelope supplied by Agentic Stream. Post-call reconciliation from
  the journaled receipt. Missing usage is `usage_unavailable`, never zero. Go's
  `costcontrol.Controller` stays the sole aggregate authority — Tamoz adds nothing aggregate.
- **Wire change.** The episode budget envelope travels on a coordinated runtime-v1 version bump in
  this phase. Both repos deploy in lockstep; the old version is rejected after switchover.
- **Deadline/cancel.** Enforced via graph `Context` deadline and cancellation token (already
  threaded by the runner). Not via delayed event arrival.

## Out of scope

- Multiple tools, skills, memory in frame (P5). Witness gateway (P3). Intent catalog (P4).

## Deletes / kills

- Any remaining event-counting budget logic.
- `task_start` counted as a tool call.

## Exit gate

1. Crash/redispatch matrix passes: before `dispatch_started`, after it, after receipt, after
   checkpoint, after decision, before terminal — fence+1 redispatch, no duplicate provider call,
   no stale acceptance, no silent retry.
2. Completed receipt replays with provider network disabled. Same parsed document, same decision.
3. Ambiguous call stays `unknown`. Never auto-repaired with a blind second call.
4. Tool call happy path + refusal path journaled with digests and byte counts.
5. Budget exhaustion mid-loop → typed terminal, visible in cost reporting.
6. Repair fires once after a succeeded-malformed response, then stops.
7. Repository gates green (`rake ci`, `rubocop`, `enola check`, durability suite via `ci_full`).

## Allowed claim

**"The real path is durable."** Level 3 of 6 (jointly with P3's replay gate).
