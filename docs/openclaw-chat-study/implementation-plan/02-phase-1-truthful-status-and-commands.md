# Phase 1 — truthful status and command parity

Status: not started — no production code changed by this planning pass.
Requires: Phase 0 (delivery fence and Telegram identity must already be fixed).

Study reference: Stage 1 (`../04-tamoz-target-architecture.md`), P1
(`../05-comparison-and-priorities.md`), root causes #2, #3, #4, #6
(`../03-tamoz-current-state.md`). This is the phase that makes the current system
**truthful**: it names the lifecycle, hands back a stable reference, exposes both
state axes, and makes the command grammar match the handlers — before any
liveness animation is added.

## Goal

A correspondent can name their turn (`request_ref`), ask `/status` and get a
read-only projection of task **and** delivery state from durable facts, and every
command the grammar advertises actually works. Conversation history stops
including output the user never confirmably saw.

## Required order

Define the state vocabulary and reason-code registry first — every later
projection and the benchmark's parity metric depend on it. Then add the request
reference to admission, then build `/status` on durable facts, then reconcile the
command registry with the handlers, then fix the history inclusion rule. CLI JSON
event identity is preserved as part of this phase so the machine contract is
stable before Phase 2 adds progress events.

## Design constraints (from the study, binding)

- Controls are parsed before task admission and never become model input. The
  command table (`Comms::Commands`) and the Gateway handlers
  (`CommsGateway#handle_command`) are kept in lockstep; an unimplemented command
  must not parse as known.
- `/status` and CLI status are projections of durable evidence
  (`CommsStore#conversation_status`, request/session/outbox rows), not a live
  guess and not a mutable in-memory cache treated as authority (invariant 12).
- Normal chat users may inspect status but may not resolve unknown effects or
  unknown delivery; those stay operator-authorized.

## Work items

1. **State vocabulary and reason-code registry.** Define the closed external
   vocabulary — `accepted`, `queued`, `running`, `waiting`, `completed`,
   `failed`, `blocked`, `stopped`, plus the independent delivery axis `pending`,
   `delivered`, `failed`, `unknown` — and a typed reason-code registry. This is
   canonical data shared by both surfaces and by the benchmark's parity metric;
   `unknown` is reserved for genuine ambiguity, never a generic error.
2. **Stable request reference.** Return a short, human-readable, non-authorizing
   request reference derived from the durable request identity in every accepted
   acknowledgement, and carry it through status, terminal output, and machine
   envelopes. The reference enables `/status`, support, recovery, and machine
   correlation; it grants no authority.
3. **`/status [reference]` on durable facts.** Build `/status` from the request,
   session, and outbox records so a caller-bound status returns, per request: the
   short reference; thread and execution identity; task state and phase; queue
   position/age when queued; last committed progress; waiting/blocked reason;
   terminal reason and next action; delivery state and unknown reason; and the
   exact operator recovery command when authority is required. Both task and
   delivery axes appear; a bare caller gets one request or an explicit list.
4. **Command registry parity.** Make `Comms::Commands` and
   `CommsGateway#handle_command` agree. Implement or remove `/new`, `/redirect`,
   and `/whoami`. Each implemented command has authorization, persistence,
   rendering, and tests; `/new` creates a new conversation generation without
   deleting audit history; `/redirect` reuses the durable redirect path with
   command-specific validation; `/whoami` shows the bound correspondent and
   conversation without conferring authority. No declared command may remain
   unavailable.
5. **History inclusion requires confirmed delivery.** Fix
   `CommsStore#conversation_history` so only confirmed successful terminal
   deliveries enter assistant conversation history. Pending or `unknown` terminal
   output must not enter a later model prompt (invariant 11).
6. **Preserve CLI JSON event identity.** Stop flattening `StreamPart` identity
   (`run_id`, `task_id`, `sequence`, `emitted_at`) in CLI JSON output. Emit stable
   NDJSON envelopes carrying the event identity and both state axes, so the
   machine contract does not change when Phase 2 adds progress events.

## Tests

- a registry-parity test proves the command table and handlers are identical and
  that an unimplemented command does not parse as known;
- a `/status`-during-work test proves a caller-bound projection with distinct
  task and delivery axes, phase, queue age, terminal reason, and next action,
  built from durable rows;
- `/new`, `/redirect`, and `/whoami` each have an auth/persistence/rendering
  test; `/whoami` confers no authority; `/new` preserves audit history;
- a delivery-then-context test proves pending/unknown terminal output is excluded
  from `conversation_history` and confirmed delivery is included;
- a CLI JSON test proves the identity fields survive round-trip and both state
  axes are present.

## Exit bar

- All six work items are done in the stated order; the command, status, history,
  and CLI JSON suites are green under `rake ci` and `ci_full` in both locales.
- Invariants 3, 5, 7, 8, 11, and 12 are verified for the touched paths.
- The command grammar and handlers are identical; `/status` shows both axes; no
  unconfirmed output enters history; the CLI machine contract is stable.
- The evidence manifest records the vocabulary/registry artifact, the test
  commands, changed files, and a statement that this phase proves plumbing only.

## Out of scope

Bounded semantic progress and cancellation-state projection (Phase 2), typed
`/compact` / `/usage` / `/context` / `/think` / `/verbose` semantics (Phase 3),
and any real-provider or live-transport usefulness claim (the benchmark).
