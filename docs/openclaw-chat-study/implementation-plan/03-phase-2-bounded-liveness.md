# Phase 2 — bounded semantic liveness

Status: not started — no production code changed by this planning pass.
Requires: Phases 0 and 1 (delivery fence, identity, state vocabulary, request
references, and `/status` must already exist).

Study reference: Stage 2 (`../04-tamoz-target-architecture.md`), P2
(`../05-comparison-and-priorities.md`), root cause #1 (`../03-tamoz-current-state.md`:
terminal-only channel projection). This is the core user-facing change: the
system stops being silent while a worker runs, without copying token streaming.

## Goal

A slow turn shows the correspondent that it is alive: `accepted`, then
`running`/`waiting`/`recovered`, then one terminal projection — bounded,
coalesced, and semantic. Cancellation becomes a visible `requested → observed →
terminal` transition. CLI gains a reconnectable status view. Progress never
enters model context and never streams tokens.

## Required order

Extend the event kinds the worker-to-outbox seam projects first, then bound and
coalesce them, then render them per surface, then make cancellation visible, then
add the reconnectable CLI view. Do not project a progress event that is not
backed by a committed durable fact.

## Design constraints (from the study, binding)

- Extend `Worker#notify_sink` and `OutboxDeliverySink::EVENT_KINDS` to carry
  claimed/running/recovered/waiting/phase milestones. Do not add a Telegram-only
  worker loop or a second event bus (`../04` seam map).
- Every projected progress event is a durable outbox effect; a Telegram edit is
  still a durable send behind `DeliveryDrainer`. Progress is bounded and coalesced
  per request and surface, and kept out of normal conversation history
  (invariant 11).
- Do not stream model tokens, raw plan prose, tool output, secrets, or lease
  detail (`../04`, "Patterns to reject").

## Work items

1. **Project lifecycle milestones.** Add the claimed/running/recovered/waiting
   and committed-phase milestones to `Worker#notify_sink` and the outbox sink's
   `EVENT_KINDS`, each carrying the request reference, sequence, phase, and
   task/delivery axes from the Phase 1 vocabulary. Milestones are derived from
   committed worker facts, never a guess.
2. **Bound and coalesce.** Coalesce progress per `(request, surface)` so a slow
   task produces at most one live projection that is updated, not a stream of new
   messages. Bound the number and rate of progress effects; a Telegram edit and a
   CLI status-line update are both bounded outbox effects.
3. **Render per surface.** Render a concise TTY-only elapsed/status line in CLI
   human mode and a single coalesced progress/waiting card in Telegram. JSON mode
   emits the same milestones as stable NDJSON envelopes with identity and both
   axes. Presentation differs; the projected meaning does not.
4. **Visible cancellation.** Make cancellation show `requested` (the user asked),
   `observed` (the `DurableRunner` saw it), and `terminal` (`stopped` or the turn
   completed first). A cancellation never claims that an already-issued external
   call stopped (invariant 9). The three states are distinct in status and in the
   terminal projection.
5. **Reconnectable CLI status view.** Add a durable, reconnectable status view so
   a CLI follow-up (or a reconnect after a dropped TTY) resumes from the request
   reference and shows current task and delivery state without re-running the
   turn.
6. **Callback and crash coverage.** Add the callback-acknowledgement and
   prompt-activation crash tests the study flagged as missing: a Telegram callback
   is acknowledged immediately, then prompt activation and the decision are
   durable across a worker crash boundary.

## Tests

- a slow-request test proves accepted → running/waiting → terminal milestones are
  projected on both surfaces, bounded and coalesced, from committed facts;
- a coalescing-bound test proves progress cannot exceed the per-request/surface
  bound and that a Telegram progress edit is a durable outbox effect;
- a progress-context test proves progress and control messages never enter
  `conversation_history`;
- a cancellation test proves requested → observed → terminal transitions, and
  that an in-flight external call is not claimed stopped;
- a callback/crash test proves immediate acknowledgement, then durable prompt
  activation and decision across a worker restart;
- a reconnect test proves the reconnectable status view resumes from the
  reference without re-running the turn.

## Exit bar

- All six work items are done in the stated order; the progress, cancellation,
  callback, and reconnect suites are green under `rake ci` and `ci_full` in both
  locales.
- Invariants 9, 11, and 12 are verified for the touched paths; progress is
  bounded, coalesced, and excluded from context.
- A slow turn is never silent between accepted and terminal on either surface,
  and no projection streams tokens or leaks internal detail.
- The evidence manifest records the test commands, changed files, and a statement
  that this phase proves plumbing only. A real-transport liveness observation, if
  any, is recorded separately and is not required for phase completion (the
  benchmark owns the real run).

## Out of scope

Typed `/compact` / `/usage` / `/context` / `/think` / `/verbose` semantics and
cross-surface recovery evidence (Phase 3), groups/media/multi-agent routing (the
frontier round), and any usefulness claim (the benchmark).
