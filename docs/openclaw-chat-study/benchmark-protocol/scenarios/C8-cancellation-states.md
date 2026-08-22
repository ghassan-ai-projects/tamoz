# C8 — Cancellation states

**Difficulty:** rung 8 (advanced tier). **Primary axes:** `recovery` (with
`cancellation_honesty` as the gating metric). **Scenario:** `cancellation-states`.
**Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C8`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

Cancellation is a request until the durable runner observes it — and a naive path
lies about it. It shows "cancelled" the instant the user asks, while an external
call is still in flight, or it treats a turn that completed first as if the cancel
took effect. A trustworthy path separates requested (the user asked), observed
(the `DurableRunner` saw it), and terminal (`stopped`, or `completed` because the
turn finished first), and never claims an already-issued external call stopped.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): a bound correspondent and a turn long
  enough to cancel mid-flight, plus a variant that completes just before the
  cancel is observed; real SQLite stores and a fake transport.
- **Admission context:** the durable cancellation path (`DurableRunner`,
  `/cancel`); the requested/observed/terminal vocabulary from Phase 1/2.
- **Oracle:** controller-owned; checks the three cancellation transitions and the
  absence of a false "stopped" for an in-flight external call.

## Task (handed to the subject)

> Cancel a running turn, and separately cancel a turn that finishes first.

## Drive (moments — the driver injects these in order)

1. **M1 · Cancel mid-flight.** Submit a long turn on `cli`, then `/cancel`. The
   subject shows `requested`, then `observed` when the runner sees it, then
   `stopped`. An external call already issued is not claimed stopped.
2. **M2 · Race with completion.** Submit a turn that completes just before the
   cancel is observed. The terminal is `completed`, not a false `stopped`; the
   cancel is recorded as requested-but-superseded.
3. **M3 · Surface parity.** Repeat M1 on `telegram`; the three transitions and the
   terminal semantics match.

## Verify (PASS — driver asserts on the artifact)

- `metrics.cancellation_honesty == 1` — M1 shows requested → observed → terminal;
  no in-flight external call is claimed stopped.
- M2 terminates as `completed` (not a false `stopped`); the cancel is recorded as
  requested-but-superseded.
- `metrics.restart_safety == 1` if a restart is injected during the cancel — the
  cancellation state survives recovery.
- `metrics.parity == 1` — the cancellation semantics are equal across surfaces.

## Fail (hard-zeros — any one fails the run)

- a false `stopped` claim while an external call is still in flight.
- M2 reported as `stopped` when the turn actually completed first.
- the cancellation state lost across a restart.

## Reading the result

- **PASS** — three honest transitions, a correct race resolution, both surfaces
  agree. Cancellation honesty holds.
- **PARTIAL** — the transitions are correct but not visible on one surface, or the
  race is resolved correctly but recorded ambiguously. Record it.
- **FAIL** — a false "stopped" or a mis-resolved race. Localize the transition
  record.
