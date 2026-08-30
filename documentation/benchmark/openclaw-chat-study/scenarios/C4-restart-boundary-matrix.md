# C4 — Restart boundary matrix

**Difficulty:** rung 4. **Primary axes:** `recovery` (with `restart_safety` as the
gating metric). **Scenario:** `restart-boundary-matrix`. **Surfaces:** `cli`,
`telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C4`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

Crashes happen mid-turn, and a trustworthy chat survives them without lying. A
naive path replays a completed effect, loses the request reference, or re-sends a
terminal answer after recovery — each a visible failure to the correspondent. This
rung restarts the worker (and gateway) at every durable boundary and asserts the
reference, sequence, task state, and delivery state all survive with no duplicate
external send.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): a bound correspondent, real SQLite
  stores, a deterministic provider, and a fake transport, with a restart hook that
  can kill and resume the worker at a named boundary.
- **Admission context:** paired correspondent; checkpoint and outbox rows are
  observable.
- **Oracle:** controller-owned; after each restart, reads the request/session/
  effect/outbox records and checks reference, sequence, task state, and delivery
  state, plus the absence of a duplicate effect or terminal send.

## Task (handed to the subject)

> Complete a turn while being restarted at each durable boundary.

## Drive (moments — the driver injects these in order)

1. **M1 · After inbound persistence.** Restart after the inbound is durably
   admitted but before a worker claim. The reference survives; the turn resumes.
2. **M2 · After acknowledgement enqueue.** Restart after the acknowledgement is
   enqueued. The acknowledgement is not duplicated.
3. **M3 · After worker claim.** Restart after the worker claims the request. The
   claim recovers via the stale-claim path; no second worker double-runs.
4. **M4 · After effect receipt.** Restart after an effect receipt is journaled.
   Replay returns the recorded receipt; the effect is not re-executed.
5. **M5 · After terminal outbox enqueue.** Restart after the terminal delivery is
   enqueued. The terminal is delivered exactly once.
6. **M6 · After transport send ambiguity.** Restart after a send whose result is
   unknown. The delivery stays `unknown`; no blind re-send on recovery.

## Verify (PASS — driver asserts on the artifact)

- `metrics.restart_safety == 1` at every boundary — reference and sequence
  preserved, correct task state, safe delivery state.
- `metrics.reference_stability == 1` — the same reference resolves the turn before
  and after each restart.
- `metrics.no_blind_retry == 1` — the M6 ambiguity produced no duplicate send on
  recovery.
- `metrics.completion == 1` — the turn reaches a correct terminal state after the
  restarts.
- `metrics.parity == 1` — the recovered outcome matches across surfaces.

## Fail (hard-zeros — any one fails the run)

- `duplicate_effect` — a journaled effect re-executed after restart.
- `duplicate_terminal_send` — the terminal delivered more than once.
- `blind_retry_after_unknown` — the M6 ambiguity re-sent on recovery.

## Reading the result

- **PASS** — every boundary recovers with a preserved reference and no duplicate.
  Recovery is honest.
- **PARTIAL** — recovery works but a reference or sequence is lost at one boundary.
  Record the boundary.
- **FAIL** — a duplicated effect, a duplicated terminal, or a blind re-send.
  Localize the boundary and the record.
